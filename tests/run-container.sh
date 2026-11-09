#!/bin/bash
# Role test in a throwaway openSUSE Leap 16.1 container: fake users and fake accounts only, the role runs inside
# the container (ansible-playbook, connection local). Exit code 0 = all OK.
#   tests/run-container.sh          # builds the test image on first use and when the nsbldr image's ansible changed
#   tests/run-container.sh build    # rebuild the test image (after changing tests/Containerfile)
# The ansible in the test image is the one of the nsbldr image (localhost/nsbldr:latest), see controller.sh.
# The container is started with --rm: it is deleted after the run together with everything the test created in
# it (test users, their homes); the role directory is mounted read-only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
role=$(dirname "$here")
engine=${CONTAINER_ENGINE:-podman}
image=localhost/ansible-role-mailclient-tests

CONTAINER_ENGINE=$engine ROLE_DIR=$role TEST_IMAGE=$image
WORK_DIR=${WORK_DIR:-${TMPDIR:-/var/tmp}/ansible-role-mailclient-tests}
mkdir -p "$WORK_DIR"
source "$here/controller.sh"
[ "${1:-}" = build ] && FORCE_BUILD=1
controller_prepare "$here/Containerfile"
exec "$engine" run --rm -v "$role:/roles/ansible-role-mailclient:ro,Z" "$image" \
  /roles/ansible-role-mailclient/tests/container/main.sh
