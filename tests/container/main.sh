#!/bin/bash
# Runs inside the test container as root: fake users, the role with fake accounts (vars/*.yml), checks after
# each run. Exit code 0 = all OK.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export ANSIBLE_ROLES_PATH=/roles ANSIBLE_NOCOLOR=1 ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_RETRY_FILES_ENABLED=false
schema=org.gnome.evolution-data-server
key=autoconfig-directory
pass=0
fail=0

ok() { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
# check <name> <command...>: one test line
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
not() { ! "$@"; }

# run_role <vars file> [ansible-playbook options]: output in $out, exit code in $rc
run_role() {
  local vars=$1; shift
  out=$(ansible-playbook -i localhost, -c local --diff "$@" -e @"$here/vars/$vars" "$here/playbook.yml" 2>&1)
  rc=$?
  echo "$out" >"/tmp/run-${vars%.yml}.log"
}
recap() { sed -n "s/.*localhost.*: ok=.* $1=\([0-9]*\).*/\1/p" <<<"$out" | head -1; }
show_on_fail() { [ "$fail" = "$1" ] || { echo "---- output"; echo "$out" | tail -40; echo "----"; }; }

# gs <user> <gsettings args...>: gsettings as the user (session bus if there is one, else a temporary bus)
gs() {
  local user=$1 uid home
  shift
  uid=$(id -u "$user"); home=$(getent passwd "$user" | cut -d: -f6)
  if [ -S "/run/user/$uid/bus" ]; then
    runuser -u "$user" -- env -i HOME="$home" PATH=/usr/bin:/bin \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" gsettings "$@"
  else
    runuser -u "$user" -- env -i HOME="$home" PATH=/usr/bin:/bin dbus-run-session -- gsettings "$@"
  fi
}
gs_get() { gs "$1" get "$schema" "$key"; }
# defaults <user>: Evolution's default sources as "key=value ..."
defaults() {
  gs "$1" list-recursively org.gnome.Evolution.DefaultSources | awk '{printf "%s=%s ", $2, $3}'
}

# fake users; testb is "logged in": its own session bus at /run/user/<uid>/bus
for u in testa:2001 testb:2002 testc:2003 testd:2004 teste:2005 testf:2006; do
  useradd -m -u "${u#*:}" -U "${u%:*}"
done
install -d -o testb -g testb -m 0700 /run/user/2002
runuser -u testb -- env -i HOME=/home/testb PATH=/usr/bin:/bin \
  dbus-daemon --session --address=unix:path=/run/user/2002/bus --fork --nopidfile >/dev/null
# testc: an existing Thunderbird profile; testd: autoconfig-directory already used by something else
install -d -o testc -g testc -m 0700 /home/testc/.thunderbird/abcd1234.default-esr
printf '[Profile0]\nName=default-esr\nIsRelative=1\nPath=abcd1234.default-esr\nDefault=1\n' >/home/testc/.thunderbird/profiles.ini
echo 'canary' >/home/testc/.thunderbird/abcd1234.default-esr/prefs.js
chown -R testc:testc /home/testc/.thunderbird
runuser -u testd -- env -i HOME=/home/testd PATH=/usr/bin:/bin dbus-run-session -- \
  gsettings set "$schema" "$key" /srv/other >/dev/null 2>&1

A=/home/testa/.config/evolution-autoconfig
B=/home/testb/.config/evolution-autoconfig
TA=/home/testa/.thunderbird
src() { cat "$A/$1.source"; }

echo "== 1. fresh users (testa no bus, testb logged in)"
f=$fail
run_role base.yml
check "run ok" test "$rc" = 0
check "testa: 9 Evolution sources (alice mail+cal+tasks+contacts, bob mail)" \
  test "$(ls "$A" | sort | tr '\n' ' ')" = "mailclient-calendar-alice.source mailclient-contacts-alice.source mailclient-mail-alice-identity.source mailclient-mail-alice-transport.source mailclient-mail-alice.source mailclient-mail-bob-identity.source mailclient-mail-bob-transport.source mailclient-mail-bob.source mailclient-tasks-alice.source "
check "testb: 6 Evolution sources (carol)" test "$(ls "$B" | wc -l)" = 6
check "sources owned by the user, 0600, dir 0700" \
  test "$(stat -c '%U %a' "$A" "$A"/* | sort -u | tr '\n' ' ')" = "testa 600 testa 700 "
check "every source has [Autoconfig] Revision" \
  test "$(grep -l -Pz '\n\[Autoconfig\]\nRevision=[0-9a-f]{16}\n$' "$A"/*.source | wc -l)" = 9
check "alice: IMAP localhost:10993 SSL, login = address" \
  grep -Pzq 'Host=localhost\nMethod=none\nPort=10993\nUser=alice@example.org\n(.*\n)*Method=ssl-on-alternate-port' \
  "$A/mailclient-mail-alice.source"
check "alice: no real Trash, all folders, junk folder Junk" \
  grep -Pzq 'UseRealTrashPath=false\nUseRealJunkPath=true\nRealJunkPath=Junk\nUseSubscriptions=false' \
  "$A/mailclient-mail-alice.source"
check "alice: replies to origin folder, Sent" \
  grep -Pzq 'SentFolder=folder://mailclient-mail-alice/Sent\nTransportUid=mailclient-mail-alice-transport\nRepliesToOriginFolder=true' \
  "$A/mailclient-mail-alice-identity.source"
check "alice: SMTP STARTTLS 10587" \
  grep -Pzq 'Port=10587\n(.*\n)*Method=starttls-on-standard-port' "$A/mailclient-mail-alice-transport.source"
check "alice: calendar path and kind" \
  grep -Pzq 'Parent=caldav-stub\n(.*\n)*Port=15232\nUser=alice@example.org\n(.*\n)*ResourcePath=/alice@example.org/calendar/\n(.*\n)*\[Calendar\]\nBackendName=caldav' \
  "$A/mailclient-calendar-alice.source"
check "alice: task list on the calendar URL" grep -q '^\[Task List\]$' "$A/mailclient-tasks-alice.source"
check "alice: address book" \
  grep -Pzq 'Parent=carddav-stub\n(.*\n)*ResourcePath=/alice@example.org/contacts/\n\n\[Address Book\]\nBackendName=carddav' \
  "$A/mailclient-contacts-alice.source"
check "bob: own servers, SMTP SSL 465, junk folder Spam, label = address" \
  bash -c "grep -q '^RealJunkPath=Spam$' $A/mailclient-mail-bob.source &&
           grep -Pzq 'Port=465\n(.*\n)*Method=ssl-on-alternate-port' $A/mailclient-mail-bob-transport.source &&
           grep -q '^DisplayName=bob@example.net$' $A/mailclient-mail-bob.source"
check "carol: Infomaniak IMAP, DAV user = short name" \
  bash -c "grep -q '^Host=mail.infomaniak.com$' $B/mailclient-mail-carol.source &&
           grep -Pzq 'Host=sync.infomaniak.com\nMethod=plain/password\nPort=443\nUser=AB12345' $B/mailclient-calendar-carol.source"
check "testa (no bus): autoconfig-directory set" test "$(gs_get testa)" = "'$A'"
check "testb (session bus): autoconfig-directory set" test "$(gs_get testb)" = "'$B'"
check "testa: Evolution defaults = alice (bob has no calendar/contacts)" \
  test "$(defaults testa)" = "default-address-book='mailclient-contacts-alice' default-calendar='mailclient-calendar-alice' default-mail-account='mailclient-mail-alice' default-mail-identity='mailclient-mail-alice-identity' default-memo-list='system' default-task-list='mailclient-tasks-alice' "
check "testb (session bus): Evolution default calendar = carol" grep -q "default-calendar='mailclient-calendar-carol'" <<<"$(defaults testb)"
check "testb: value also in the dconf file (session bus stopped)" \
  bash -c "pkill -u testb dbus-daemon; pkill -u testb dconf-service; sleep 1; rm -f /run/user/2002/bus;
           test \"\$(runuser -u testb -- env -i HOME=/home/testb PATH=/usr/bin:/bin dbus-run-session -- gsettings get $schema $key)\" = \"'$B'\""
check "TB profiles.ini: profile default, install hash" \
  grep -Pzq 'Path=default\n(.*\n)*\[Install3DDF446CE6CB1A45\]\nDefault=default\nLocked=1' "$TA/profiles.ini"
check "TB installs.ini" grep -Pzq '\[3DDF446CE6CB1A45\]\nDefault=default\nLocked=1' "$TA/installs.ini"
check "TB user.js: only comments and user_pref lines" \
  not grep -Ev '^(//.*|user_pref\("[^"]+", .+\);|)$' "$TA/default/user.js"
check "TB user.js: alice IMAP SSL, no Trash, all folders, replies in origin folder" \
  bash -c "grep -qF 'user_pref(\"mail.server.server_alice.socketType\", 3);' $TA/default/user.js &&
           grep -qF 'user_pref(\"mail.server.server_alice.delete_model\", 2);' $TA/default/user.js &&
           grep -qF 'user_pref(\"mail.server.server_alice.using_subscription\", false);' $TA/default/user.js &&
           grep -qF 'user_pref(\"mail.identity.id_alice.fcc_reply_follows_parent\", true);' $TA/default/user.js"
check "TB user.js: folder URIs with %40, junk Spam for bob" \
  bash -c "grep -qF '\"imap://alice%40example.org@localhost/Sent\"' $TA/default/user.js &&
           grep -qF '\"imap://bob%40example.net@imap.example.net/Spam\"' $TA/default/user.js"
check "TB user.js: SMTP bob SSL, alice STARTTLS" \
  bash -c "grep -qF 'user_pref(\"mail.smtpserver.smtp_bob.try_ssl\", 3);' $TA/default/user.js &&
           grep -qF 'user_pref(\"mail.smtpserver.smtp_alice.try_ssl\", 2);' $TA/default/user.js"
check "TB user.js: calendar + address book alice, junk whitelist" \
  bash -c "grep -qF 'user_pref(\"calendar.registry.mailclient-alice.uri\", \"https://localhost:15232/alice@example.org/calendar/\");' $TA/default/user.js &&
           grep -qF 'user_pref(\"ldap_2.servers.mailclient_alice.dirType\", 102);' $TA/default/user.js &&
           grep -qF 'user_pref(\"mail.server.server_bob.whiteListAbURI\", \"jscarddav://abook-alice.sqlite\");' $TA/default/user.js"
check "TB user.js: account list and defaults" \
  bash -c "grep -qF 'user_pref(\"mail.accountmanager.accounts\", \"account_alice,account_bob,account_local\");' $TA/default/user.js &&
           grep -qF 'user_pref(\"mail.smtpservers\", \"smtp_alice,smtp_bob\");' $TA/default/user.js &&
           grep -qF 'user_pref(\"mail.accountmanager.defaultaccount\", \"account_alice\");' $TA/default/user.js"
check "TB user.js: default calendar alice, newest message on top" \
  bash -c "grep -qF 'user_pref(\"calendar.registry.mailclient-alice.calendar-main-default\", true);' $TA/default/user.js &&
           test \$(grep -c calendar-main-default $TA/default/user.js) = 1 &&
           grep -qF 'user_pref(\"mailnews.default_sort_type\", 18);' $TA/default/user.js &&
           grep -qF 'user_pref(\"mailnews.default_sort_order\", 2);' $TA/default/user.js"
check "TB files owned by the user" test "$(stat -c %U "$TA" "$TA"/* "$TA"/default/* | sort -u)" = testa
check "no account data in the output (no_log)" not grep -Eq '@example\.|AB12345|exampleorg' <<<"$out"
check "restart notes shown" bash -c 'grep -q "evolution --force-shutdown" <<<"$0" && grep -q "next start of Thunderbird" <<<"$0"' "$out"
show_on_fail "$f"

echo "== 2. second run: nothing changes"
f=$fail
sums=$(cat "$A"/* "$TA"/*.ini "$TA"/default/user.js | sha256sum)
run_role base.yml
check "run ok" test "$rc" = 0
check "changed=0" test "$(recap changed)" = 0
check "files unchanged" test "$(cat "$A"/* "$TA"/*.ini "$TA"/default/user.js | sha256sum)" = "$sums"
show_on_fail "$f"

echo "== 3. check mode"
f=$fail
run_role base.yml --check
check "run ok, changed=0" test "$rc/$(recap changed)" = 0/0
show_on_fail "$f"

echo "== 4. account bob removed"
f=$fail
# the user chose another task list and bob as default mail account in Evolution
gs testa set org.gnome.Evolution.DefaultSources default-task-list 'userchoice' >/dev/null 2>&1
gs testa set org.gnome.Evolution.DefaultSources default-mail-account 'mailclient-mail-bob' >/dev/null 2>&1
run_role nobob.yml
check "run ok" test "$rc" = 0
check "bob's sources gone, alice's kept" \
  bash -c "test \$(ls $A | grep -c bob) = 0 && test \$(ls $A | grep -c alice) = 6"
check "TB user.js without bob" \
  bash -c "! grep -q bob $TA/default/user.js && grep -qF '\"account_alice,account_local\"' $TA/default/user.js"
check "Evolution defaults: user's choice kept, removed bob replaced by alice" \
  bash -c 'grep -q "default-task-list='"'userchoice'"'" <<<"$0" && grep -q "default-mail-account='"'mailclient-mail-alice'"'" <<<"$0"' "$(defaults testa)"
check "testb untouched (not in the list)" test "$(ls "$B" | wc -l)" = 6
show_on_fail "$f"

echo "== 5. existing Thunderbird profile → stop"
f=$fail
run_role foreign-tb.yml
check "run fails" test "$rc" != 0
check "message" grep -q 'already holds another Thunderbird' <<<"$out"
check "existing profile untouched, nothing added" \
  bash -c "test \"\$(cat /home/testc/.thunderbird/abcd1234.default-esr/prefs.js)\" = canary &&
           test ! -e /home/testc/.thunderbird/default && grep -q abcd1234 /home/testc/.thunderbird/profiles.ini"
show_on_fail "$f"

echo "== 6. autoconfig-directory used by something else → stop"
f=$fail
run_role foreign-autoconfig.yml
check "run fails" test "$rc" != 0
check "message" grep -q "already '/srv/other' - not taken over" <<<"$out"
check "no sources written, value kept" \
  bash -c "test ! -e /home/testd/.config/evolution-autoconfig && test \"\$(runuser -u testd -- env -i HOME=/home/testd PATH=/usr/bin:/bin dbus-run-session -- gsettings get $schema $key)\" = \"'/srv/other'\""
show_on_fail "$f"

echo "== 7. invalid accounts → stop before any change"
f=$fail
run_role bad-id.yml
check "bad id: run fails with message" \
  bash -c 'test "$0" != 0 && grep -q "teste/Bad-Id: account id must be" <<<"$1"' "$rc" "$out"
run_role bad-provider.yml
check "unknown provider: run fails with message" \
  bash -c 'test "$0" != 0 && grep -q "teste/frank: unknown provider" <<<"$1"' "$rc" "$out"
check "message without account data" not grep -q '@example\.' <<<"$out"
check "nothing written for teste" test ! -e /home/teste/.thunderbird -a ! -e /home/teste/.config/evolution-autoconfig
show_on_fail "$f"

# negative control for the no_log check of scenario 1: with no_log false the same grep must find the data
echo "== 8. no_log false shows the data (the no_log check can fail)"
f=$fail
run_role nolog-off.yml
check "run ok, account data in the diff" bash -c 'test "$0" = 0 && grep -q "frank@example.org" <<<"$1"' "$rc" "$out"
show_on_fail "$f"

echo "== 9. helpers/mailclient-reset.py (testa), then the role recreates everything"
f=$fail
asa() { runuser -u testa -- env -i HOME=/home/testa USER=testa PATH=/usr/bin:/bin "$@"; }
reset_helper() { out=$(asa python3 /roles/ansible-role-mailclient/helpers/mailclient-reset.py "$@" 2>&1); rc=$?; }
# mess as after hand-made setups and use; plus things that must stay
asa bash -c 'mkdir -p ~/.config/evolution/sources ~/.local/share/evolution/mail/local ~/.cache/evolution/mail \
  ~/.cache/thunderbird/default ~/Thunderbird ~/.mozilla/firefox ~/Documents &&
  echo "[Data Source]" >~/.config/evolution/sources/0123abcd.source && echo m >~/.local/share/evolution/mail/local/x &&
  echo c >~/.cache/evolution/mail/x && echo "user_pref(\"x\", 1);" >~/.thunderbird/default/prefs.js &&
  echo c >~/.cache/thunderbird/default/x && echo keep >~/.mozilla/firefox/keep && echo keep >~/Documents/keep &&
  dbus-run-session -- dconf write /org/gnome/evolution/mail/prompt-on-expunge false'
# file list of testa; without ~/.cache/dconf: dconf's runtime file, created by reads without XDG_RUNTIME_DIR
mess() { find /home/testa -mindepth 1 -not -path "/home/testa/.cache/dconf*" | sort | sha256sum; }
before=$(mess)
reset_helper --dry-run
check "dry run: lists the mess, changes nothing" \
  bash -c 'test "$0" = 0 && grep -q "delete  /home/testa/.thunderbird " <<<"$1" &&
           grep -q "reset   dconf /org/gnome/evolution/" <<<"$1" && grep -q "dry run - nothing changed" <<<"$1"' "$rc" "$out"
cp /usr/bin/sleep /tmp/thunderbird
runuser -u testa -- /tmp/thunderbird 60 &
tb=$!
sleep 1
reset_helper <<<reset
check "Thunderbird running: stops" bash -c 'test "$0" != 0 && grep -q "Thunderbird is running" <<<"$1"' "$rc" "$out"
kill "$tb"; wait "$tb" 2>/dev/null
reset_helper <<<no
check "not confirmed: stops" bash -c 'test "$0" != 0 && grep -q "not confirmed - nothing changed" <<<"$1"' "$rc" "$out"
check "nothing changed so far" test "$(mess)" = "$before"
reset_helper --backup /home/testa/reset.tar.gz <<<reset
check "reset ok" test "$rc" = 0
check "Evolution and Thunderbird data gone" \
  bash -c 'for p in .config/evolution .local/share/evolution .cache/evolution .config/evolution-autoconfig .thunderbird \
             .cache/thunderbird Thunderbird; do test ! -e "/home/testa/$p" || exit 1; done'
check "dconf trees empty (autoconfig-directory reset)" \
  bash -c 'test -z "$(runuser -u testa -- env -i HOME=/home/testa PATH=/usr/bin:/bin dconf dump /org/gnome/evolution/)" &&
           test "$(runuser -u testa -- env -i HOME=/home/testa PATH=/usr/bin:/bin dbus-run-session -- gsettings get '"$schema $key"')" = "'"''"'"'
check "other files kept (browser, documents)" \
  bash -c 'test "$(cat /home/testa/.mozilla/firefox/keep /home/testa/Documents/keep)" = "keep
keep"'
check "backup 0600 with the deleted files and dconf" \
  bash -c 'test "$(stat -c %a /home/testa/reset.tar.gz)" = 600 &&
           tar -tzf /home/testa/reset.tar.gz | grep -qx ".thunderbird/default/prefs.js" &&
           tar -tzf /home/testa/reset.tar.gz | grep -qx "dconf_org_gnome_evolution.ini"'
check "keyring warning (no keyring in the container)" grep -q "keyring passwords not cleared" <<<"$out"
reset_helper --dry-run
check "second dry run: nothing to do" grep -q "nothing to do" <<<"$out"
run_role nobob.yml
check "role run after reset ok" test "$rc" = 0
check "role recreated Evolution sources, key and Thunderbird profile" \
  bash -c 'test "$(ls '"$A"' | wc -l)" = 6 && test -f '"$TA"'/default/user.js && test -f '"$TA"'/profiles.ini &&
           test "$(runuser -u testa -- env -i HOME=/home/testa PATH=/usr/bin:/bin dbus-run-session -- gsettings get '"$schema $key"')" = "'"'$A'"'"'
show_on_fail "$f"

echo "== 10. separate task list URL, own colours, helpers/mailclient-colors.py"
f=$fail
F=/home/testf/.config/evolution-autoconfig
TF=/home/testf/.thunderbird/default/user.js
run_role colors.yml
check "run ok" test "$rc" = 0
check "Evolution calendar: own URL, colour" \
  grep -Pzq 'ResourcePath=/cal/\n(.*\n)*\[Calendar\]\nBackendName=caldav\nColor=#112233\nSelected=true' "$F/mailclient-calendar-gina.source"
check "Evolution task list: own URL, colour (lower case)" \
  grep -Pzq 'ResourcePath=/tasks/\n(.*\n)*\[Task List\]\nBackendName=caldav\nColor=#aabbcc\nSelected=true' "$F/mailclient-tasks-gina.source"
check "Evolution: no colour without color (alice)" not grep -q '^Color=' "$A/mailclient-calendar-alice.source"
check "TB: calendar entry with colour, default" \
  bash -c "grep -qF 'user_pref(\"calendar.registry.mailclient-gina.uri\", \"http://127.0.0.1:18080/cal/\");' $TF &&
           grep -qF 'user_pref(\"calendar.registry.mailclient-gina.color\", \"#112233\");' $TF &&
           grep -qF 'user_pref(\"calendar.registry.mailclient-gina.calendar-main-default\", true);' $TF"
check "TB: second entry for the task list, own colour, not default" \
  bash -c "grep -qF 'user_pref(\"calendar.registry.mailclient-gina-tasks.name\", \"Gina Tasks\");' $TF &&
           grep -qF 'user_pref(\"calendar.registry.mailclient-gina-tasks.uri\", \"http://127.0.0.1:18080/tasks/\");' $TF &&
           grep -qF 'user_pref(\"calendar.registry.mailclient-gina-tasks.color\", \"#aabbcc\");' $TF &&
           ! grep -q 'mailclient-gina-tasks.calendar-main-default' $TF"
check "TB: same URL → one entry (alice), no colour" \
  bash -c "! grep -q 'mailclient-alice-tasks' $TA/default/user.js && ! grep -q 'mailclient-alice.color' $TA/default/user.js"
check "TB user.js still only comments and user_pref lines" not grep -Ev '^(//.*|user_pref\("[^"]+", .+\);|)$' "$TF"
python3 "$here/davstub.py" 18080 &
stub=$!
sleep 1
colors_helper() {
  out=$(runuser -u testf -- env -i HOME=/home/testf PATH=/usr/bin:/bin MAILCLIENT_DAV_PASSWORD="$1" \
    python3 /roles/ansible-role-mailclient/helpers/mailclient-colors.py "${@:2}" </dev/null 2>&1)
  rc=$?
}
colors_helper dav-test-pw
check "helper: colours from the server for the inventory (alpha stripped)" \
  bash -c 'test "$0" = 0 && grep -qx "gina:" <<<"$1" && grep -qx "  color: \"#112233\"" <<<"$1" &&
           grep -qx "  tasks_color: \"#aabbcc\"" <<<"$1"' "$rc" "$out"
check "helper: password not in the output" not grep -q dav-test-pw <<<"$out"
colors_helper dav-test-pw --debug
check "helper --debug: URL, user, password source and answer shown" \
  bash -c 'test "$0" = 0 && grep -q "DEBUG: mailclient-calendar-gina: URL http://127.0.0.1:18080/cal/, user testdav" <<<"$1" &&
           grep -q "DEBUG: password: from MAILCLIENT_DAV_PASSWORD" <<<"$1" && grep -q "Basic <redacted>" <<<"$1" &&
           grep -q "DEBUG: answer: 207" <<<"$1"' "$rc" "$out"
check "helper --debug: neither password nor Basic credentials shown" \
  bash -c '! grep -q -e dav-test-pw -e "$(printf testdav:dav-test-pw | base64)" <<<"$0"' "$out"
colors_helper wrong-pw
check "helper: wrong password → 401, fails, password not shown" \
  bash -c 'test "$0" != 0 && grep -q "mailclient-calendar-gina: server answered 401 (wrong user/password?)" <<<"$1" &&
           ! grep -q wrong-pw <<<"$1"' "$rc" "$out"
kill "$stub"; wait "$stub" 2>/dev/null
run_role bad-color.yml
check "invalid colour: run fails with message" \
  bash -c 'test "$0" != 0 && grep -q "teste/frank: color must be" <<<"$1"' "$rc" "$out"
show_on_fail "$f"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
