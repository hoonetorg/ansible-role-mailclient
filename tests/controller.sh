# tests/controller.sh - sourced by the test scripts (host side); the same file in every role repo with tests.
#
# The ansible in the test image is what the nsbldr image (the production controller) provides, whatever
# nsbldr image that is (Debian- or EE-based):
#   - ansible-core and its Python dependencies at nsbldr's versions (pip, venv /opt/ansible in the test image)
#   - controller-side Python libraries of collections (CONTROLLER_LIBS) at nsbldr's versions, if nsbldr has them
#   - the collections this role uses (modules, filters, tests, lookups, callbacks found in the role), copied out
#     of the nsbldr image (nothing from Galaxy); a collection nsbldr does not have is an error
# Every run reads these versions from nsbldr and compares them with the label controller.versions of the test
# image; the test image is rebuilt only when they differ (or with FORCE_BUILD=1). The versions are printed.
#
# needs from the caller: CONTAINER_ENGINE, ROLE_DIR, TEST_IMAGE, WORK_DIR; optional: NSBLDR_IMAGE
# the test Containerfile gets: build arg ANSIBLE_PINS (pip requirements), directory collections/ in the context

NSBLDR_IMAGE=${NSBLDR_IMAGE:-localhost/nsbldr:latest}
CONTROLLER_LIBS="xmltodict netaddr jmespath passlib dnspython"

# collections (namespace.name) the role uses, one per line
controller_collections() {
  (
    set +e  # greps without matches are normal here, whatever the caller set
    cd "$ROLE_DIR" || exit 1
    {
      # module keys in task lists (not in defaults/vars: dotted keys there are data, e.g. browser prefs)
      grep -rhoE '^\s*(-\s+)?[a-z0-9_]+\.[a-z0-9_]+\.[a-z0-9_]+:' tasks handlers tests --include='*.yml' 2>/dev/null \
        | sed -E 's/^\s*(-\s+)?//; s/:$//'
      # filters, tests, lookups
      grep -rhoE '\|\s*[a-z0-9_]+\.[a-z0-9_]+\.[a-z0-9_]+' . --include='*.yml' --include='*.j2' 2>/dev/null \
        | sed -E 's/^\|\s*//'
      grep -rhoE '\bis\s+(not\s+)?[a-z0-9_]+\.[a-z0-9_]+\.[a-z0-9_]+' . --include='*.yml' --include='*.j2' 2>/dev/null \
        | awk '{print $NF}'
      grep -rhoE "(lookup|query)\(\s*['\"][a-z0-9_]+\.[a-z0-9_]+\.[a-z0-9_]+" . --include='*.yml' --include='*.j2' 2>/dev/null \
        | sed -E "s/.*['\"]//"
      # callbacks in the test ansible.cfg files
      grep -rhE '^\s*(callbacks_enabled|stdout_callback)\s*=' . --include='*.cfg' 2>/dev/null \
        | sed 's/.*=//' | tr ',' '\n' | tr -d ' '
      # module_utils of collections in the role's own modules
      grep -rhoE 'ansible_collections\.[a-z0-9_]+\.[a-z0-9_]+' . --include='*.py' 2>/dev/null \
        | sed 's/^ansible_collections\.//; s/$/.x/'
      true  # a grep without matches must not fail the caller (set -e, pipefail)
    } | awk -F. 'NF>=3{print $1"."$2}' | { grep -vE '^ansible\.(builtin|legacy|module_utils)$' || true; } | sort -u
  )
}

# controller_info <collection...>: read from the nsbldr image, lines
#   python <version> | pin <name>==<version> | collection <name> <version> <path> | missing <name>
controller_info() {
  "$CONTAINER_ENGINE" run --rm --log-driver=none --network=none --user root -w /nsbldr \
    -e ANSIBLE_LOG_PATH=/dev/null -e CONTROLLER_LIBS="$CONTROLLER_LIBS" --entrypoint python3 "$NSBLDR_IMAGE" -c '
import importlib, importlib.metadata as md, json, os, re, sys
print("python %d.%d.%d" % sys.version_info[:3])
pins = {"ansible-core": md.version("ansible-core")}
names = [re.split(r"[\s<>=!~;\[(]", r, maxsplit=1)[0] for r in md.requires("ansible-core") or [] if "extra ==" not in r]
for name in names + os.environ["CONTROLLER_LIBS"].split():
    try:
        pins[name] = md.version(name)
    except md.PackageNotFoundError:
        pass
for name in sorted(pins, key=str.lower):
    print("pin %s==%s" % (name, pins[name]))
from ansible.plugins.loader import init_plugin_loader
init_plugin_loader()
for c in sys.argv[1:]:
    try:
        path = list(importlib.import_module("ansible_collections." + c).__path__)[0]
        ver = json.load(open(os.path.join(path, "MANIFEST.json")))["collection_info"]["version"]
        print("collection", c, ver, path)
    except Exception:
        print("missing", c)
' "$@"
}

# controller_prepare <Containerfile>: test image matches the nsbldr image (rebuilt if not); prints the versions
controller_prepare() {
  local containerfile=$1 colls info fp have why build name ver path
  "$CONTAINER_ENGINE" image inspect "$NSBLDR_IMAGE" >/dev/null 2>&1 \
    || { echo "FAIL nsbldr image $NSBLDR_IMAGE missing (build it: cnsbldr --build)"; return 1; }
  colls=$(controller_collections)
  # shellcheck disable=SC2086
  info=$(controller_info $colls) || { echo "FAIL reading the versions from $NSBLDR_IMAGE"; return 1; }
  if grep -q '^missing ' <<<"$info"; then
    echo "FAIL the role uses collections $NSBLDR_IMAGE does not have: $(sed -n 's/^missing //p' <<<"$info" | paste -sd' ')"
    return 1
  fi
  fp=$(awk '$1=="pin"{print $2} $1=="collection"{print $2"=="$3}' <<<"$info" | paste -sd' ')
  echo "controller ($NSBLDR_IMAGE, python $(awk '$1=="python"{print $2}' <<<"$info")): $fp"
  if "$CONTAINER_ENGINE" image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
    have=$("$CONTAINER_ENGINE" image inspect "$TEST_IMAGE" --format '{{index .Config.Labels "controller.versions"}}')
    [ "${FORCE_BUILD:-}" != 1 ] && [ "$have" = "$fp" ] && return 0
    why=${FORCE_BUILD:+rebuild requested}; why=${why:-controller versions changed}
  else
    why="no test image yet"
  fi
  echo "building $TEST_IMAGE ($why)"
  # build context: the collections copied out of nsbldr; removed after the build
  build=$WORK_DIR/build
  rm -rf "$build"; mkdir -p "$build/collections/ansible_collections"
  while read -r _ name ver path; do
    mkdir -p "$build/collections/ansible_collections/${name%%.*}/${name#*.}"
    "$CONTAINER_ENGINE" run --rm --log-driver=none --network=none --user root --entrypoint tar "$NSBLDR_IMAGE" \
      -C "$path" --exclude=__pycache__ -cf - . \
      | tar -C "$build/collections/ansible_collections/${name%%.*}/${name#*.}" --no-same-owner -xf - \
      || { echo "FAIL copying $name from $NSBLDR_IMAGE"; return 1; }
  done < <(grep '^collection ' <<<"$info")
  "$CONTAINER_ENGINE" build -t "$TEST_IMAGE" --label "controller.versions=$fp" \
    --build-arg "ANSIBLE_PINS=$(awk '$1=="pin"{print $2}' <<<"$info" | paste -sd' ')" \
    -f "$containerfile" "$build" || { echo "FAIL building $TEST_IMAGE"; return 1; }
  rm -rf "$build"
}
