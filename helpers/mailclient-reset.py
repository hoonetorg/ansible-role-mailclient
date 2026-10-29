#!/usr/bin/python3
"""Reset Evolution and/or Thunderbird of the current user completely, to start over with the accounts from
ansible-role-mailclient (or from scratch).

Deletes (only what exists; --dry-run shows it with sizes and changes nothing):
  Evolution:
    ~/.config/evolution, ~/.local/share/evolution, ~/.cache/evolution: all accounts, calendars, task lists,
      address books, filters, signatures, templates, "On This Computer" mail/contacts/calendars, caches
    ~/.config/evolution-autoconfig: the account files of ansible-role-mailclient
    dconf /org/gnome/evolution/ and /org/gnome/evolution-data-server/: all Evolution settings, incl. the role's
      GSettings autoconfig-directory
    the passwords of these accounts in the GNOME keyring (secret-tool; skipped with a warning if there is no
      unlocked keyring, e.g. not logged in; --keep-passwords keeps them)
  Thunderbird:
    ~/.thunderbird: all profiles - local mail and Local Folders, saved passwords, certificate exceptions, address
      books, calendars, add-ons, settings
    ~/.cache/thunderbird, ~/.config/thunderbird (newer versions), an empty ~/Thunderbird (stray dir of some
      versions)
Mail, calendars and contacts on the servers are not touched. GNOME Online Accounts are not touched (their
accounts come back in Evolution).

Before deleting: shows everything, asks for confirmation (type "reset"), writes a backup tar of all of it (mode
0600 - it contains Thunderbird's saved passwords; --no-backup skips it; the keyring passwords are not in it).
Stops if Thunderbird is running; stops Evolution and its data server (all evolution* processes of the user, as
evolution --force-shutdown does) before and after deleting.

Afterwards: run ansible-role-mailclient (e.g. --tags mailclient) - it recreates the accounts - then log out/in
(or reboot) and start the clients; they ask for the passwords once.

Run as the user (not root), in the desktop session or via ssh; stdlib only:
  mailclient-reset.py [--dry-run] [--clients evolution,thunderbird] [--backup FILE | --no-backup]
                      [--keep-passwords]
"""

import argparse
import datetime
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

HOME = os.path.expanduser("~")
DCONF_TREES = ["/org/gnome/evolution/", "/org/gnome/evolution-data-server/"]
CLIENTS = ("evolution", "thunderbird")
PATHS = {
    "evolution": [".config/evolution", ".local/share/evolution", ".cache/evolution", ".config/evolution-autoconfig"],
    "thunderbird": [".thunderbird", ".cache/thunderbird", ".config/thunderbird"],
}
TB_PROCESSES = ("thunderbird", "thunderbird-bin")
# Evolution and evolution-data-server (comm is cut to 15 characters: evolution-sourc, evolution-calen, ...)
EVOLUTION_PREFIX = "evolution"


def die(msg):
    sys.exit("ERROR: " + msg + " - nothing changed")


def human(size):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return "%.0f %s" % (size, unit) if unit == "B" else "%.1f %s" % (size, unit)
        size /= 1024


def du(path):
    if os.path.islink(path) or not os.path.isdir(path):
        return os.lstat(path).st_size
    total = 0
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def bus_env():
    """Environment with the user's session bus; None if there is none (not logged in)"""
    env = dict(os.environ)
    if not env.get("DBUS_SESSION_BUS_ADDRESS"):
        bus = "/run/user/%d/bus" % os.getuid()
        if not os.path.exists(bus):
            return None
        env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + bus
    return env


def run(args, env=None, timeout=60):
    try:
        return subprocess.run(args, env=env, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(args, 1, "", str(e))


def dconf(args):
    """dconf on the session bus, else on a temporary one (writes need the dconf service; reads don't)"""
    env = bus_env()
    if env is None:
        return run(["dbus-run-session", "--", "dconf"] + args)
    return run(["dconf"] + args, env=env)


def processes(match):
    """PIDs of the user's processes whose name matches"""
    uid, pids = os.getuid(), []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if os.stat("/proc/" + pid).st_uid != uid or int(pid) == os.getpid():
                continue
            with open("/proc/%s/comm" % pid) as f:
                if match(f.read().strip()):
                    pids.append(int(pid))
        except OSError:
            pass
    return pids


def stop_evolution():
    """Like evolution --force-shutdown (killev), which would also create an empty ~/.config/evolution"""
    match = lambda name: name.startswith(EVOLUTION_PREFIX)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in processes(match):
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        for _ in range(50):
            if not processes(match):
                return
            time.sleep(0.1)


def remove(path):
    if os.path.islink(path) or not os.path.isdir(path):
        os.unlink(path)
    else:
        shutil.rmtree(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="only show what would be deleted")
    ap.add_argument("--clients", default=",".join(CLIENTS), help="evolution,thunderbird (default: both)")
    ap.add_argument("--backup", help="backup tar file (default: ~/mailclient-reset-<time>.tar.gz)")
    ap.add_argument("--no-backup", action="store_true", help="no backup tar")
    ap.add_argument("--keep-passwords", action="store_true", help="keep Evolution's passwords in the keyring")
    args = ap.parse_args()

    if os.getuid() == 0:
        die("run as the user whose mail clients are reset, not as root")
    clients = [c for c in args.clients.split(",") if c]
    if not clients or set(clients) - set(CLIENTS):
        die("--clients: evolution and/or thunderbird")

    paths = [os.path.join(HOME, p) for c in clients for p in PATHS[c] if os.path.lexists(os.path.join(HOME, p))]
    stray = os.path.join(HOME, "Thunderbird")
    if "thunderbird" in clients and os.path.isdir(stray) and not os.path.islink(stray) and not os.listdir(stray):
        paths.append(stray)
    dumps = {}
    uids = []
    if "evolution" in clients:
        for tree in DCONF_TREES:
            out = run(["dconf", "dump", tree]).stdout
            if out.strip():
                dumps[tree] = out
        for d in (".config/evolution/sources", ".config/evolution-autoconfig"):
            d = os.path.join(HOME, d)
            if os.path.isdir(d):
                uids += [f[:-len(".source")] for f in sorted(os.listdir(d)) if f.endswith(".source")]
        uids = sorted(set(uids))

    print("Mail client reset for %s (%s):" % (os.environ.get("USER", os.getuid()), ", ".join(clients)))
    for p in paths:
        print("  delete  %-45s %10s" % (p, human(du(p))))
    for tree in dumps:
        print("  reset   dconf %s" % tree)
    if uids and not args.keep_passwords:
        print("  clear   keyring passwords of %d Evolution sources" % len(uids))
    if not (paths or dumps or (uids and not args.keep_passwords)):
        print("  nothing to do")
        return
    if args.dry_run:
        print("dry run - nothing changed")
        return
    if "thunderbird" in clients and processes(lambda name: name in TB_PROCESSES):
        die("Thunderbird is running - close it first")

    try:
        answer = input('Mail, calendars and contacts on the servers stay. Type "reset" to delete the above: ')
    except EOFError:
        answer = ""
    if answer.strip() != "reset":
        die("not confirmed")

    if not args.no_backup:
        backup = args.backup or os.path.join(
            HOME, "mailclient-reset-%s.tar.gz" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        old_umask = os.umask(0o077)
        try:
            with tarfile.open(backup, "x:gz") as tar:
                for p in paths:
                    tar.add(p, arcname=os.path.relpath(p, HOME))
                for tree, out in dumps.items():
                    with tempfile.NamedTemporaryFile("w", delete=False) as f:
                        f.write(out)
                    tar.add(f.name, arcname="dconf" + tree.rstrip("/").replace("/", "_") + ".ini")
                    os.unlink(f.name)
        except (OSError, tarfile.TarError) as e:
            die("backup failed: %s" % e)
        finally:
            os.umask(old_umask)
        print("backup: %s (0600, contains Thunderbird's saved passwords - delete it when no longer needed)" % backup)

    if "evolution" in clients:
        stop_evolution()
        if uids and not args.keep_passwords:
            env = bus_env()
            if env is None or not shutil.which("secret-tool"):
                print("WARNING: keyring passwords not cleared (%s)" %
                      ("not logged in" if env is None else "secret-tool missing"))
            else:
                failed = [u for u in uids if run(["secret-tool", "clear", "e-source-uid", u], env=env).returncode]
                if failed:
                    print("WARNING: keyring passwords of %d sources not cleared (keyring locked?)" % len(failed))
    for p in paths:
        remove(p)
        print("deleted %s" % p)
    for tree in dumps:
        r = dconf(["reset", "-f", tree])
        print("reset dconf %s%s" % (tree, "" if r.returncode == 0 else " FAILED: " + r.stderr.strip()))
    if "evolution" in clients:
        # a data server started meanwhile (e.g. by GNOME Shell's calendar) would still hold the old accounts
        stop_evolution()

    print("\nDone. Next: run ansible-role-mailclient (e.g. --tags mailclient), then log out/in (or reboot) and "
          "start the clients - they ask for the passwords once.")


if __name__ == "__main__":
    main()
