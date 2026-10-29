#!/bin/bash
# Role test in a throwaway openSUSE Leap 16.1 container: fake users and fake accounts only, the role runs inside
# the container (ansible-playbook, connection local). Exit code 0 = all OK.
#   tests/run-container.sh          # builds the test image on first use
#   tests/run-container.sh build    # rebuild the test image (after changing tests/Containerfile)
# The container is started with --rm: it is deleted after the run together with everything the test created in
# it (test users, their homes); the role directory is mounted read-only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
role=$(dirname "$here")
engine=${CONTAINER_ENGINE:-podman}
image=localhost/ansible-role-mailclient-tests

if [ "${1:-}" = build ] || ! "$engine" image inspect "$image" >/dev/null 2>&1; then
  "$engine" build -t "$image" "$here"
fi
exec "$engine" run --rm -v "$role:/roles/ansible-role-mailclient:ro,Z" "$image" \
  /roles/ansible-role-mailclient/tests/container/main.sh
