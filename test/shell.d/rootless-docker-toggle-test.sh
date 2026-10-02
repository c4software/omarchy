#!/bin/bash
#
# Rootless Docker runs a per-user daemon next to the system one. Setup installs
# the rootless pieces, keeps the daemon alive with linger, enables the packaged
# user unit, and selects it through a docker context (not DOCKER_HOST, so
# `sudo docker` keeps reaching the system daemon). Remove undoes the unit and
# the context and leaves the system daemon alone.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
home="$test_dir/home"
runtime="$test_dir/run"
stub_bin="$test_dir/bin"
calls="$test_dir/calls"
mkdir -p "$home" "$runtime" "$stub_bin"

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$stub_bin/$1"
  chmod +x "$stub_bin/$1"
}

stub sudo 'exec "$@"'
stub gum 'exit "${GUM_ANSWER:-0}"'
stub grep 'exec /usr/bin/grep "$@" "${SUBID_FILE:?}"' # setup checks /etc/subuid and /etc/subgid
stub omarchy-pkg-add 'echo "pkg-add $*" >>"$CALLS"'
stub omarchy-pkg-aur-add 'echo "aur-add $*" >>"$CALLS"'
stub loginctl 'echo "loginctl $*" >>"$CALLS"'
stub systemctl '
echo "systemctl $*" >>"$CALLS"
if [[ $* == *is-enabled* ]]; then exit "${UNIT_ENABLED:-1}"; fi
if [[ $* == *"enable --now docker.service"* ]]; then python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$XDG_RUNTIME_DIR/docker.sock"; fi
exit 0'
stub docker '
echo "docker $*" >>"$CALLS"
if [[ "$1 $2" == "context inspect" ]]; then exit "${CONTEXT_EXISTS:-1}"; fi
exit 0'

subid="$test_dir/subid"

run() { # command UNIT_ENABLED GUM_ANSWER CONTEXT_EXISTS SUBID_LINE
  rm -f "$calls" "$runtime/docker.sock"
  printf '%s\n' "$5" >"$subid"
  env HOME="$home" USER="tester" XDG_RUNTIME_DIR="$runtime" CALLS="$calls" \
    UNIT_ENABLED="$2" GUM_ANSWER="$3" CONTEXT_EXISTS="$4" SUBID_FILE="$subid" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    bash "$ROOT/bin/$1" >/dev/null 2>&1
}

called() { grep -Fqx -- "$1" "$calls" 2>/dev/null; }

# Setup, confirmed -> packages, linger, unit, context created and selected.
run omarchy-setup-security-rootless-docker 1 0 1 "tester:100000:65536"
called "pkg-add rootlesskit slirp4netns" || fail "setup installs rootlesskit and slirp4netns"
called "aur-add docker-rootless-extras" || fail "setup installs docker-rootless-extras from the AUR"
called "loginctl enable-linger tester" || fail "setup enables linger"
called "systemctl --user enable --now docker.service" || fail "setup enables the packaged user unit"
called "docker context create rootless --description Rootless Docker (tester) --docker host=unix://$runtime/docker.sock" || fail "setup creates the rootless context on the user socket"
called "docker context use rootless" || fail "setup selects the rootless context"
pass "setup installs, enables the user daemon, and selects it through a context"

# Setup, context already there -> reused, not recreated.
run omarchy-setup-security-rootless-docker 1 0 0 "tester:100000:65536"
! grep -q "context create" "$calls" || fail "setup reuses an existing rootless context"
called "docker context use rootless" || fail "setup still selects the existing context"
pass "setup reuses an existing rootless context"

# Setup, declined -> nothing installed or enabled.
run omarchy-setup-security-rootless-docker 1 1 1 "tester:100000:65536"
! grep -qE "pkg-add|aur-add|loginctl|enable --now|context" "$calls" || fail "declined setup changes nothing"
pass "declined setup changes nothing"

# Setup, no subordinate range -> stops before installing anything.
run omarchy-setup-security-rootless-docker 1 0 1 "someone-else:100000:65536" || true
! grep -qE "pkg-add|aur-add|enable --now" "$calls" || fail "setup refuses without a subuid/subgid range"
pass "setup refuses without a subordinate UID/GID range"

# Setup, already enabled -> no-op.
run omarchy-setup-security-rootless-docker 0 0 1 "tester:100000:65536"
! grep -qE "pkg-add|enable --now|context" "$calls" || fail "setup is a no-op when already enabled"
pass "setup is a no-op when rootless Docker is already enabled"

# Setup never touches the system daemon.
run omarchy-setup-security-rootless-docker 1 0 1 "tester:100000:65536"
! grep -E "^systemctl " "$calls" | grep -v -- "--user" | grep -q . || fail "setup must not touch the system docker units"
pass "setup leaves the system daemon alone"

# Remove -> unit disabled, default context back, rootless context removed.
run omarchy-remove-security-rootless-docker 0 0 0 ""
called "systemctl --user disable --now docker.service docker.socket" || fail "remove disables the user unit"
called "docker context use default" || fail "remove switches back to the default context"
called "docker context rm -f rootless" || fail "remove deletes the rootless context"
pass "remove disables the user daemon and restores the default context"

# Remove, not enabled -> no-op.
run omarchy-remove-security-rootless-docker 1 0 0 ""
! grep -qE "disable|context use" "$calls" || fail "remove is a no-op when rootless Docker is off"
pass "remove is a no-op when rootless Docker is off"
