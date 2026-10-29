# Filters of ansible-role-mailclient: the inventory account list of a user resolved against the providers
# (validation, defaults) and the Evolution source files per account. Error messages name the user and the
# account id only, never an address or login (personal data).

import re
from urllib.parse import quote, urlsplit

from ansible.errors import AnsibleFilterError

SECURITY = ("ssl", "starttls")
COLOR = re.compile(r"#[0-9a-fA-F]{6}")


def _fail(where, msg):
    raise AnsibleFilterError("mailclient %s: %s" % (where, msg))


def _server(where, kind, base, override):
    """imap/smtp of the provider, overridden key by key by the account's own imap/smtp"""
    server = dict(base or {})
    server.update(override or {})
    if not server.get("host"):
        _fail(where, "%s host missing (no provider and no %s)" % (kind, kind))
    try:
        port = int(server.get("port"))
    except (TypeError, ValueError):
        _fail(where, "%s port missing or not a number" % kind)
    if server.get("security") not in SECURITY:
        _fail(where, "%s security must be one of %s" % (kind, ", ".join(SECURITY)))
    return {"host": str(server["host"]), "port": port, "security": server["security"]}


def _dav(where, key, url):
    """CalDAV/CardDAV URL split into the parts Evolution wants; None without URL"""
    if not url:
        return None
    parts = urlsplit(str(url))
    if parts.scheme not in ("https", "http") or not parts.hostname:
        _fail(where, "%s must be an http(s) URL" % key)
    return {
        "url": str(url),
        "host": parts.hostname,
        "port": parts.port or (443 if parts.scheme == "https" else 80),
        "path": parts.path or "/",
        "tls": parts.scheme == "https",
    }


def _color(where, key, value):
    """Calendar/task list colour "#rrggbb" or None"""
    if value in (None, ""):
        return None
    if not COLOR.fullmatch(str(value)):
        _fail(where, '%s must be "#rrggbb"' % key)
    return str(value).lower()


def mailclient_accounts(accounts, providers, folder_defaults, user=""):
    """Validated accounts with provider data, folders, login etc. filled in"""
    out, ids = [], set()
    if not isinstance(accounts, list):
        _fail(user, "accounts must be a list")
    for account in accounts:
        if not isinstance(account, dict):
            _fail(user, "every account must be a mapping")
        aid = str(account.get("id", ""))
        where = "%s/%s" % (user, aid)
        if not re.fullmatch(r"[a-z0-9]+", aid):
            _fail(where, "account id must be [a-z0-9]+ (used in file names and account keys)")
        if aid in ids:
            _fail(where, "account id used twice")
        ids.add(aid)
        address = str(account.get("address") or "")
        if not address:
            _fail(where, "address missing")
        provider = {}
        if account.get("provider"):
            if account["provider"] not in providers:
                _fail(where, "unknown provider %r" % account["provider"])
            provider = providers[account["provider"]] or {}
        folders = dict(folder_defaults)
        folders.update(provider.get("folders") or {})
        folders.update(account.get("folders") or {})
        login = str(account.get("login") or address)

        def dav(key):
            url = account.get(key) or str(provider.get(key) or "").replace("{address}", address)
            return _dav(where, key, url)

        calendar = dav("calendar_url")
        # task list: own URL (e.g. united-domains) or the calendar's
        tasks = dav("tasks_url") or calendar
        color = _color(where, "color", account.get("color"))

        out.append({
            "id": aid,
            "label": str(account.get("label") or address),
            "name": str(account.get("name") or address),
            "address": address,
            "login": login,
            # user part of Thunderbird's imap:// folder URIs (e.g. @ → %40)
            "login_quoted": quote(login, safe=""),
            "imap": _server(where, "imap", provider.get("imap"), account.get("imap")),
            "smtp": _server(where, "smtp", provider.get("smtp"), account.get("smtp")),
            "folders": folders,
            "dav_user": str(account.get("dav_user") or login),
            "calendar": calendar,
            "tasks": tasks,
            "tasks_separate": bool(tasks) and tasks != calendar,
            "color": color,
            "tasks_color": _color(where, "tasks_color", account.get("tasks_color")) or color,
            "contacts": dav("contacts_url"),
        })
    return out


def mailclient_validate(users, providers, folder_defaults):
    """True if the accounts of all users are valid, else the error of the first invalid one"""
    for user in users:
        mailclient_accounts(user.get("accounts") or [], providers, folder_defaults, user.get("user", ""))
    return True


def mailclient_evolution_sources(accounts):
    """Evolution source files per account: uid (= file name without .source), template, data"""
    out = []
    for a in accounts:
        mail = "mailclient-mail-" + a["id"]
        out += [
            {"uid": mail, "template": "mail-account", "account": a},
            {"uid": mail + "-identity", "template": "mail-identity", "account": a},
            {"uid": mail + "-transport", "template": "mail-transport", "account": a},
        ]
        if a["calendar"]:
            out.append({"uid": "mailclient-calendar-" + a["id"], "template": "dav", "account": a,
                        "dav": a["calendar"], "kind": "Calendar", "color": a["color"]})
        if a["tasks"]:
            out.append({"uid": "mailclient-tasks-" + a["id"], "template": "dav", "account": a,
                        "dav": a["tasks"], "kind": "Task List", "color": a["tasks_color"]})
        if a["contacts"]:
            out.append({"uid": "mailclient-contacts-" + a["id"], "template": "dav", "account": a,
                        "dav": a["contacts"], "kind": "Address Book"})
    return out


# Evolution's default sources (GSettings org.gnome.Evolution.DefaultSources) → kind of source
DEFAULT_SOURCES = (
    ("default-mail-account", "mail-account"),
    ("default-mail-identity", "mail-identity"),
    ("default-calendar", "Calendar"),
    ("default-task-list", "Task List"),
    ("default-address-book", "Address Book"),
)


def mailclient_evolution_defaults(sources):
    """Default source per GSettings key: the first source of that kind (= first account that has one)"""
    out = {}
    for key, kind in DEFAULT_SOURCES:
        uids = [s["uid"] for s in sources if s.get("kind", s["template"]) == kind]
        if uids:
            out[key] = uids[0]
    return out


class FilterModule:
    def filters(self):
        return {
            "mailclient_accounts": mailclient_accounts,
            "mailclient_validate": mailclient_validate,
            "mailclient_evolution_sources": mailclient_evolution_sources,
            "mailclient_evolution_defaults": mailclient_evolution_defaults,
        }
