# ansible-role-mailclient

Installs Evolution and/or Thunderbird and gives named users the same accounts in both: mail (IMAP/SMTP),
calendar and task list (CalDAV), address book (CardDAV). Same behaviour in both clients:

- no Trash: delete = gone (a folder deleted into the Trash by one client stays greyed in the other)
- all folders shown, not only subscribed ones
- replies and forwards saved in the folder of the original message
- junk to the junk folder on the server (Thunderbird: the account's address book is the junk whitelist)
- the first account is the default: mail account, and (first account that has one) calendar, task list, address
  book; in Evolution only while no other default was chosen there (a choice made in Evolution stays)
- Thunderbird: message list sorted by date, newest on top. Evolution has no setting for it: click the Date column
  once (with Evolution's default "same view settings for all folders" it applies to every folder)
- calendar and task list colours from the inventory (`color`, `tasks_color`): neither client takes the server's
  colour for calendars it didn't add itself (they copy it only in their own "add calendar" dialog, and never
  follow later changes on the server - checked up to Evolution 3.62 / Thunderbird 158); read them once with
  `helpers/mailclient-colors.py`
- default mail client for `mailto:` links (`default_client`, default: the first of `clients`): written to the
  user's `~/.config/mimeapps.list` (what GNOME Settings → Default Apps writes; other entries stay); neither client
  asks at start to become the default. The inventory decides: a change in GNOME Settings is set back at the next
  run (`default_client: ''` leaves it to the user)
- Evolution: the contacts of the server address books are in the "Birthdays & Anniversaries" calendar

No password is stored in any file: each client asks once per account (Evolution: GNOME keyring, Thunderbird:
its own password manager). Thunderbird asks for a calendar's login in a plain dialog that shows only the server,
without the user name (it sends no login until one is saved): enter the DAV user (`dav_user`, e.g. the Infomaniak
short name; default: the mail login) and the password, and let Thunderbird save it - once per server.

The users must exist (run after ansible-role-user). Only the listed users are touched.

## How

**Evolution**: per user the account sources are written to `~/.config/evolution-autoconfig/`
(`mailclient-*.source`, only this role writes there) and GSettings `org.gnome.evolution-data-server
autoconfig-directory` is set to that directory (once; as the user, on the session bus if the user is logged in,
else on a temporary `dbus-run-session` bus). At its next start evolution-source-registry copies the sources into
Evolution's own `~/.config/evolution/sources/`, replaces its copy whenever a file changes (`[Autoconfig]
Revision` = hash of the content) and deletes its copy when the file is gone (account removed from the inventory).
Active after `evolution --force-shutdown` (or log out/in) and starting Evolution. Accounts added by hand in
Evolution stay untouched.

**Thunderbird**: fixed profile `~/.thunderbird/default` (`profiles.ini`/`installs.ini` written only when
missing, Thunderbird maintains them afterwards) and its `user.js`, which Thunderbird applies at every start.
Accounts added by hand in Thunderbird drop out of the account list at the next start - add them to the inventory
instead. After changing an outgoing server by hand: restart Thunderbird (seen on 140: the old settings stayed
active until a restart).

The role **stops** (fails, changes nothing for that user) when:
- `~/.thunderbird` already holds another profile or unknown content (existing mail data)
- `autoconfig-directory` is already set to another directory (reset it as the user to hand it over:
  `gsettings reset org.gnome.evolution-data-server autoconfig-directory`)
- an account is invalid (id not `[a-z0-9]+` or twice, no address, unknown provider, no imap/smtp, `label` or
  `name` with a line break or a backslash, colour not `"#rrggbb"`)
- `default_client` is not one of `clients` (or has no desktop entry for the OS family)

Not done: removing a user from `users` or a client from `clients` leaves that user's files/packages in place.

## Start over: `helpers/mailclient-reset.py`

Removes Evolution and/or Thunderbird of one user completely (accounts, settings, local data, caches, the
Evolution passwords in the keyring), so the next role run sets them up fresh. Run it as that user (not root),
Thunderbird closed:

```bash
helpers/mailclient-reset.py --dry-run                 # what would be deleted, with sizes - changes nothing
helpers/mailclient-reset.py                           # asks, then: backup tar, stop Evolution, delete
helpers/mailclient-reset.py --clients thunderbird     # only one client
```

Deleted:
- Evolution: `~/.config/evolution`, `~/.local/share/evolution`, `~/.cache/evolution` (all accounts, calendars,
  address books, filters, signatures, "On This Computer" mail/contacts/calendars), `~/.config/evolution-autoconfig`
  (this role's files), dconf `/org/gnome/evolution/` and `/org/gnome/evolution-data-server/` (all Evolution
  settings incl. `autoconfig-directory`), the keyring passwords of these accounts (`--keep-passwords` keeps them;
  skipped with a warning without an unlocked keyring, e.g. via ssh)
- Thunderbird: `~/.thunderbird` (all profiles: local mail, saved passwords, certificate exceptions, add-ons),
  `~/.cache/thunderbird`, `~/.config/thunderbird`, an empty `~/Thunderbird`

Not touched: mail, calendars and contacts on the servers, other files in the home (browsers etc.), GNOME Online
Accounts. Before deleting it writes `~/mailclient-reset-<time>.tar.gz` (mode 0600; contains Thunderbird's saved
passwords - delete it when no longer needed; `--backup FILE`, `--no-backup`).

Then: run the role (`--tags mailclient`), log out/in (or reboot), start the clients and enter the passwords once.
The role's files are needed again because the reset also removes them - log out/in alone doesn't bring the
accounts back.

## Colours: `helpers/mailclient-colors.py`

Reads the colours of the role's calendars and task lists from the servers and prints them for the inventory. Run
it as the user in the desktop session, after Evolution has stored the passwords (it takes them from the GNOME
keyring, else asks; never printed):

```bash
helpers/mailclient-colors.py
# colours from the servers - put the lines into the account with this id (users[].accounts[]):
work:
  color: "#3a87ad"
own:
  color: "#d06b64"
  tasks_color: "#8fbc8f"
```

Put the lines into the accounts, run the role, restart the clients. Colour changed on the server: run it again.
For a test server with a self-signed certificate: `--cafile <cert>` (or `--insecure`, local test server only).
A server answers with an error: `--debug` shows per calendar/task list the file, URL, user, where the password
came from, the request (Authorization redacted) and the answer, on stderr; the password is never shown.

## Requirements

- controller: collection `community.general` (zypper on openSUSE)
- target: `runuser` (util-linux); the role installs the clients plus `gsettings` and `dbus-run-session`
  (Leap 16.1: `glib2-tools`, `gsettings-backend-dconf`, `dbus-1-daemon`) and for the reset helper `secret-tool`
  and `dconf`

## Variables

```yaml
mailclient:
  clients: [evolution, thunderbird]   # default; or one of them
  # packages: {thunderbird: [MozillaThunderbird]}   # default: vars/main.yml per OS family
  # default_client: evolution         # mailto: links; default: the first of clients; '' = leave it to the user
  # desktop_ids: {evolution: org.gnome.Evolution.desktop}   # default: vars/main.yml per OS family
  no_log: true                        # default; false shows file diffs incl. account data (debugging, fake data)
  # providers: {...}                  # add providers (merged with the defaults: infomaniak, united-domains)
  # folders: {sent: Sent, drafts: Drafts, archive: Archive, junk: Junk, templates: Templates}   # defaults
  users:
    - user: alice                     # existing user
      accounts:
        - id: work                    # short, [a-z0-9]+, unique per user - used in file names and account
                                      # keys, don't change later
          label: Work                 # name of account/calendar/address book in the clients (default: address)
          name: Alice Example         # sender name (default: address)
          address: alice@example.com
          provider: infomaniak
          dav_user: AB12345           # Infomaniak short name (calendar/contacts login, app password)
          calendar_url: "https://sync.infomaniak.com/calendars/AB12345/…"     # from the Infomaniak sync wizard
          contacts_url: "https://sync.infomaniak.com/addressbooks/AB12345/…"  # (config.infomaniak.com → GNU/Linux)
          color: "#3a87ad"            # calendar colour (default: the client's), see helpers/mailclient-colors.py
        - id: own
          address: alice@example.net
          provider: united-domains
          login: examplenet-0001      # mailbox name from the united-domains customer menu
          calendar_url: "https://…/calendar/"
          tasks_url: "https://…/tasks/"    # own task list URL (default: calendar_url)
          tasks_color: "#8fbc8f"      # task list colour (default: color)
          # folders: {junk: Spam}     # only if the server's folder names differ
        - id: other                   # another hoster: own servers instead of provider
          address: alice@example.org
          imap: {host: imap.example.org, port: 993, security: ssl}         # ssl | starttls
          smtp: {host: smtp.example.org, port: 587, security: starttls}
```

Per account optional: `label`, `name`, `login` (default: address), `dav_user` (default: login), `calendar_url`,
`tasks_url` (default: calendar_url), `contacts_url` (provider pattern with `{address}` if the provider has one),
`color`, `tasks_color` (`"#rrggbb"`; default: none = the client's colour / `color`), `folders`, `imap`/`smtp`
(override the provider key by key). Thunderbird gets one calendar per URL: with its own `tasks_url` the task list
is a second calendar "<label> Tasks".

Account data is personal: keep real accounts in the vault (e.g. `accounts: "{{ vault_mailclient_alice_accounts
}}"`), not in plain inventory files. With `no_log: true` (default) the role output shows user names and account
ids only.

A provider (public server data):

```yaml
mailclient:
  providers:
    mailtestserver:                   # e.g. a local test server
      imap: {host: localhost, port: 10993, security: ssl}
      smtp: {host: localhost, port: 10587, security: starttls}
      calendar_url: "https://localhost:15232/{address}/calendar/"
      contacts_url: "https://localhost:15232/{address}/contacts/"
      # folders: {junk: Spam}
```

Folder names of the real providers can't be verified without an account: check them once in the client (e.g.
`Junk` vs `Spam`) and set `folders` if they differ. Folders below the inbox (some servers keep all special folders
there): full path with `/` as separator, whatever the server uses, e.g. `folders: {sent: INBOX/Sent, junk:
INBOX/Spam}` - both clients write folder paths with `/`.

## Tests

```bash
tests/run-container.sh          # ~1 min (first run builds the test image: Leap 16.1 + ansible + the clients)
tests/run-container.sh build    # rebuild the test image after changing tests/Containerfile
```

Runs the role in a throwaway Leap 16.1 container (deleted afterwards, `--rm`) with fake users and fake accounts
(`tests/container/vars/`): files and their content, GSettings value with and without a session bus, second run
`changed=0`, check mode, account removal, stops (existing Thunderbird profile, foreign autoconfig directory,
invalid accounts), no account data in the output (and the negative control with `no_log: false`), the reset
helper (dry run, stops while Thunderbird runs / unconfirmed, deletes exactly its paths, backup, then the role
recreates everything), separate task list URL and colours, the colour helper against a small DAV stub, the
default mail client (new and existing `mimeapps.list`, `default_client: ''`, not in `clients`), the `label` check.

The clients themselves (do they show the accounts, folders, calendars?) are checked by hand with fake accounts
against a local test server: repo `mailtestserver`.

## License

Apache-2.0

Created with the help of AI
