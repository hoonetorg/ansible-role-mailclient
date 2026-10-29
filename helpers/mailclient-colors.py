#!/usr/bin/python3
"""Read the colours of the calendars and task lists from the servers, for the inventory (color, tasks_color).

Neither Evolution nor Thunderbird takes over the server's colour for calendars set up by ansible-role-mailclient
(they copy it only in their own "add calendar" dialog), so the role sets the colours from the inventory. This
reads them once: per calendar/task list of the role (~/.config/evolution-autoconfig/mailclient-{calendar,tasks}-*
.source: URL and user) it asks the server for its calendar-color, with the password Evolution stored in the GNOME
keyring (secret-tool), else it asks for it. Passwords are never printed. Output: per account id the lines to put
into that account in the inventory; run the role afterwards. A colour changed on the server later: run it again.

Run as the user, in the desktop session after Evolution has stored the passwords (stdlib only):
  mailclient-colors.py [--cafile FILE | --insecure] [--debug]
  --cafile: CA/certificate to trust (e.g. a test server's self-signed one); --insecure: no certificate check
  (only for a local test server - the password goes to whoever answers); --debug: show per calendar/task list
  the file, URL, user, where the password came from, the request (Authorization redacted) and the answer
  (stderr; the password itself is never shown)
"""

import argparse
import base64
import configparser
import getpass
import glob
import os
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

AUTOCONFIG = os.path.expanduser("~/.config/evolution-autoconfig")
PROPFIND = (b'<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:i="http://apple.com/ns/ical/">'
            b'<d:prop><i:calendar-color/></d:prop></d:propfind>')
COLOR_TAG = "{http://apple.com/ns/ical/}calendar-color"
DEBUG = False


def debug(msg):
    if DEBUG:
        print("DEBUG: " + msg, file=sys.stderr)


def bus_env():
    """Environment with the user's session bus; None if there is none (not logged in)"""
    env = dict(os.environ)
    if not env.get("DBUS_SESSION_BUS_ADDRESS"):
        bus = "/run/user/%d/bus" % os.getuid()
        if not os.path.exists(bus):
            return None
        env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + bus
    return env


def password(uid, user):
    """MAILCLIENT_DAV_PASSWORD (tests), the keyring entry Evolution stored for this source, else ask"""
    if os.environ.get("MAILCLIENT_DAV_PASSWORD"):
        debug("password: from MAILCLIENT_DAV_PASSWORD")
        return os.environ["MAILCLIENT_DAV_PASSWORD"]
    env = bus_env()
    if env is not None:
        try:
            r = subprocess.run(["secret-tool", "lookup", "e-source-uid", uid], env=env, capture_output=True,
                               text=True, timeout=60)
            if r.returncode == 0 and r.stdout:
                debug("password: from the keyring (secret-tool lookup e-source-uid %s)" % uid)
                return r.stdout.rstrip("\n")
            debug("password: not in the keyring (secret-tool exit %d)" % r.returncode)
        except (OSError, subprocess.TimeoutExpired) as e:
            debug("password: secret-tool failed: %s" % e)
    else:
        debug("password: no session bus, keyring not asked")
    if not sys.stdin.isatty():
        return None
    debug("password: asking")
    return getpass.getpass("password of %s for %s (not in the keyring): " % (user, uid))


def source(path):
    """URL and user of an Evolution CalDAV source file"""
    ini = configparser.ConfigParser(interpolation=None, strict=False)
    ini.optionxform = str
    ini.read(path)
    tls = ini.get("Security", "Method", fallback="tls") == "tls"
    host = ini.get("Authentication", "Host")
    port = ini.get("Authentication", "Port", fallback="")
    # no default port in the URL: urllib would send it in the Host header (sync.infomaniak.com:443), which some
    # front servers don't route (404)
    if port == ("443" if tls else "80"):
        port = ""
    url = "%s://%s%s%s" % ("https" if tls else "http", host, ":" + port if port else "",
                           ini.get("WebDAV Backend", "ResourcePath", fallback="/"))
    return url, ini.get("Authentication", "User", fallback="")


def debug_response(status, headers, body):
    debug("answer: %s" % status)
    for k, v in headers.items():
        debug("  %s: %s" % (k, v))
    debug("  body (first 2000 bytes): %r" % body[:2000])


def color(url, user, pw, context):
    req = urllib.request.Request(url, data=PROPFIND, method="PROPFIND", headers={
        "Depth": "0",
        "Content-Type": "application/xml; charset=utf-8",
        "Authorization": "Basic " + base64.b64encode(("%s:%s" % (user, pw)).encode()).decode(),
    })
    if DEBUG:
        debug("request: PROPFIND %s" % req.full_url)
        debug("  Host: %s" % req.host)
        for k, v in req.header_items():
            debug("  %s: %s" % (k, "Basic <redacted>" if k.lower() == "authorization" else v))
        debug("  User-Agent: %s (added by urllib)" % urllib.request.OpenerDirector().addheaders[0][1])
        debug("  body: %r" % PROPFIND)
    try:
        with urllib.request.urlopen(req, timeout=30, context=context) as r:
            body = r.read()
            if DEBUG:
                debug_response(r.status, r.headers, body)
    except urllib.error.HTTPError as e:
        if DEBUG:
            debug_response(e.code, e.headers, e.read())
        raise
    tree = ET.fromstring(body)
    for el in tree.iter(COLOR_TAG):
        m = re.match(r"\s*(#[0-9a-fA-F]{6})", el.text or "")   # #RRGGBB, also from #RRGGBBAA
        if m:
            return m.group(1).lower()
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cafile", help="CA/certificate file to trust")
    ap.add_argument("--insecure", action="store_true", help="no certificate check (local test server only)")
    ap.add_argument("--debug", action="store_true", help="show file, URL, user, request and answer (stderr)")
    args = ap.parse_args()
    global DEBUG
    DEBUG = args.debug
    if os.getuid() == 0:
        sys.exit("ERROR: run as the user whose calendars are read, not as root")
    context = ssl.create_default_context(cafile=args.cafile)
    if args.insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

    files = sorted(glob.glob(os.path.join(AUTOCONFIG, "mailclient-calendar-*.source"))
                   + glob.glob(os.path.join(AUTOCONFIG, "mailclient-tasks-*.source")))
    if not files:
        sys.exit("ERROR: no calendars of ansible-role-mailclient in %s" % AUTOCONFIG)
    colors, failed = {}, False
    for path in files:
        uid = os.path.basename(path)[:-len(".source")]
        kind, account = uid.split("-", 2)[1:]
        key = "color" if kind == "calendar" else "tasks_color"
        url, user = source(path)
        debug("%s: file %s" % (uid, path))
        debug("%s: URL %s, user %s" % (uid, url, user))
        pw = password(uid, user)
        if not pw:
            print("%s: no password (not in the keyring, not asked)" % uid, file=sys.stderr)
            failed = True
            continue
        try:
            colors.setdefault(account, {})[key] = color(url, user, pw, context)
            debug("%s: colour %s" % (uid, colors[account][key]))
        except urllib.error.HTTPError as e:
            print("%s: server answered %s%s" % (uid, e.code, " (wrong user/password?)" if e.code == 401 else ""),
                  file=sys.stderr)
            failed = True
        except (urllib.error.URLError, OSError, ET.ParseError) as e:
            print("%s: %s" % (uid, getattr(e, "reason", e)), file=sys.stderr)
            failed = True

    print("# colours from the servers - put the lines into the account with this id (users[].accounts[]):")
    for account in sorted(colors):
        c = colors[account]
        print("%s:" % account)
        cal, tasks = c.get("color"), c.get("tasks_color")
        if cal:
            print('  color: "%s"' % cal)
        if tasks and tasks != cal:
            print('  tasks_color: "%s"' % tasks)   # default of tasks_color is color
        if not cal and not tasks:
            print("  # no colour on the server")
        elif "color" in c and not cal:
            print("  # calendar: no colour on the server")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
