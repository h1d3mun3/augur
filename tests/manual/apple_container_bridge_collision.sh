#!/usr/bin/env bash
# Manual repro: does a second Apple Container project's `augur up` cut off the first one's
# network, and does restarting the second network's vmnet helper first prevent it?
#
# Suspected cause (apple/container#2051): a network's bridge unit (bridge100, bridge101, …) is
# fixed at its first attachment and kept after its bridge goes down. If network A later takes the
# same unit while B's bridge is down, B's next attachment reconfigures A's live bridge, and A's
# containers lose the host gateway where A's augur-proxy listens.
#
# Two phases, each starting from a clean `container system stop/start`:
#   1. without a helper restart → expected: one shared bridge, project A's proxy unreachable
#   2. `launchctl kickstart -k` on B's network helper right before B's second `up`
#      → hoped: two bridges, project A still reachable
#
# The two throwaway projects live on a RAM disk (or a temp dir with --no-ramdisk) and are
# destroyed on exit, together with their state under ~/.augur. Results and proxy logs are kept
# in $TMPDIR.
#
# WARNING: `container system stop` stops EVERY running Apple Container container on this Mac.
#
# Usage: tests/manual/apple_container_bridge_collision.sh [--yes] [--no-ramdisk]
#   AUGUR=/path/to/augur   augur to run (default: augur on PATH)
#   RAMDISK_MB=256         RAM disk size
set -euo pipefail

AUGUR="${AUGUR:-augur}"
PREFIX="bridgerepro"
VOL="augur-${PREFIX}"
RAMDISK_MB="${RAMDISK_MB:-256}"
ASSUME_YES=false
USE_RAMDISK=true

for a in "$@"; do
    case "$a" in
        -y|--yes)     ASSUME_YES=true ;;
        --no-ramdisk) USE_RAMDISK=false ;;
        -h|--help)    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

RESULTS_DIR="${TMPDIR:-/tmp}/augur-${PREFIX}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/run.log"
exec > >(tee -a "$LOG") 2>&1

say()  { printf '\033[36m[repro]\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31m[repro] %s\033[0m\n' "$*"; exit 1; }

# ── preflight ────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only."
for c in container launchctl hdiutil diskutil shasum ifconfig; do
    command -v "$c" >/dev/null || fail "'$c' not found."
done
command -v "$AUGUR" >/dev/null || [[ -x "$AUGUR" ]] || fail "augur not found (set AUGUR=/path/to/augur)."

container system status >/dev/null 2>&1 || container system start >/dev/null
running="$(container list 2>/dev/null | tail -n +2 || true)"
echo "This stops ALL Apple Container containers (container system stop) twice."
if [[ -n "$running" ]]; then
    echo "Currently running:"
    echo "$running" | sed 's/^/    /'
fi
if ! $ASSUME_YES; then
    read -rp "Continue? [y/N] " yn
    [[ "$yn" == [yY]* ]] || exit 1
fi

# ── workspace (RAM disk) ─────────────────────────────────────────────────────
RAMDEV=""
if $USE_RAMDISK; then
    [[ -e "/Volumes/$VOL" ]] && fail "/Volumes/$VOL already exists (left over from an earlier run?). Eject it first."
    RAMDEV="$(hdiutil attach -nomount "ram://$((RAMDISK_MB * 2048))" | awk '{print $1}')"
    diskutil erasevolume APFS "$VOL" "$RAMDEV" >/dev/null
    ROOT="/Volumes/$VOL"
else
    ROOT="$(mktemp -d "${TMPDIR:-/tmp}/augur-${PREFIX}.XXXXXX")"
fi
mkdir -p "$ROOT/${PREFIX}-a" "$ROOT/${PREFIX}-b"
DIR_A="$(cd "$ROOT/${PREFIX}-a" && pwd)"
DIR_B="$(cd "$ROOT/${PREFIX}-b" && pwd)"

# The names augur derives from a workspace path (see workspace_slug / workspace_path_hash /
# make_container_name / egress_network_name in augur).
path_hash() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }
SWIFT_TAG="${SWIFT_VERSION:-latest}"; SWIFT_TAG="${SWIFT_TAG//./-}"
KEY_A="${PREFIX}-a-$(path_hash "$DIR_A")"
KEY_B="${PREFIX}-b-$(path_hash "$DIR_B")"
CTR_A="augur-${KEY_A}-swift-${SWIFT_TAG}"
CTR_B="augur-${KEY_B}-swift-${SWIFT_TAG}"
NET_A="augur-${KEY_A}-net"
NET_B="augur-${KEY_B}-net"
HELPER_B="gui/$(id -u)/com.apple.container.container-network-vmnet.${NET_B}"

cleanup() {
    set +e
    hdr "cleanup"
    local d k
    for k in "$KEY_A" "$KEY_B"; do
        cp "$HOME/.augur/proxy/${k}-container.log" "$RESULTS_DIR/" 2>/dev/null
    done
    for d in "$DIR_A" "$DIR_B"; do
        [[ -d "$d" ]] && (cd "$d" && "$AUGUR" destroy >/dev/null 2>&1)
    done
    # Exact per-project paths only; destroy leaves history/agents dirs and proxy files behind.
    for k in "$KEY_A" "$KEY_B"; do
        rm -rf "$HOME/.augur/claude-projects/$k" "$HOME/.augur/claude-agents/$k" \
               "$HOME/.augur/claude-carryover/$k"
        rm -f "$HOME/.augur/proxy/$k.allowlist" "$HOME/.augur/proxy/${k}-container.log"
    done
    if [[ -n "$RAMDEV" ]]; then
        hdiutil detach "$RAMDEV" >/dev/null 2>&1 || hdiutil detach -force "$RAMDEV" >/dev/null 2>&1
    else
        rm -rf "$ROOT"
    fi
    say "results: $RESULTS_DIR"
}
trap cleanup EXIT

# ── helpers ──────────────────────────────────────────────────────────────────
bridges() {
    ifconfig -a 2>/dev/null | awk '
        function flush() { if (isb) printf "    %s  inet=%s  members=%d\n", name, (ip == "" ? "-" : ip), m; isb = 0 }
        /^[a-z0-9]+:/ { flush(); name = $1; sub(":", "", name); isb = (name ~ /^bridge1[0-9][0-9]$/); ip = ""; m = 0; next }
        isb && /[[:space:]]inet / { ip = $2 }
        isb && /member:/ { m++ }
        END { flush() }'
}
show_bridges() { local b; b="$(bridges)"; echo "${b:-    (no bridge1xx interfaces)}"; }
bridge_count() { bridges | grep -c . || true; }

gateway() {
    container network inspect "$1" 2>/dev/null | grep -iE 'gateway' \
        | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1 || true
}

# HTTP status through the container's own proxy; 000 = the proxy is unreachable (network dead).
# Any real status (even a 403 deny) proves the guest still reaches its host-side proxy.
probe() {
    container exec "$1" /bin/sh -c \
        'curl -s -o /dev/null -w "%{http_code}" --max-time 8 -x "$HTTPS_PROXY" https://api.anthropic.com' \
        2>/dev/null || true
}
alive() { local c; c="$(probe "$1")"; [[ -n "$c" && "$c" != "000" ]]; }

augur_in() {   # $1 = dir, rest = augur args. Output to a per-call log; nonzero is reported, not fatal.
    local dir="$1"; shift
    local out; out="$RESULTS_DIR/augur-$(basename "$dir")-$1-$(date +%H%M%S).log"
    if (cd "$dir" && "$AUGUR" "$@") >"$out" 2>&1; then
        say "augur $* in $(basename "$dir"): ok"
    else
        say "augur $* in $(basename "$dir"): FAILED (log: $out)"
        tail -n 15 "$out" | sed 's/^/      /'
        return 1
    fi
}

restart_system() {
    say "container system stop/start..."
    container system stop >/dev/null 2>&1 || true
    container system start >/dev/null
    local t=30
    until container system status >/dev/null 2>&1; do
        ((t-- > 0)) || fail "container system did not come back."
        sleep 1
    done
}

kick_helper_b() {
    launchctl print "$HELPER_B" >/dev/null 2>&1 \
        || { say "helper not registered: $HELPER_B"; launchctl list | grep container-network-vmnet | sed 's/^/      /'; return 1; }
    say "launchctl kickstart -k $HELPER_B"
    launchctl kickstart -k "$HELPER_B" || return 1
    local t=20
    until launchctl print "$HELPER_B" 2>/dev/null | grep -q 'state = running'; do
        ((t-- > 0)) || { say "helper did not report running again"; return 1; }
        sleep 0.5
    done
    sleep 1
}

# ── one phase ────────────────────────────────────────────────────────────────
declare RES_1="" RES_2=""
run_phase() {   # $1 = phase number, $2 = true to restart B's helper before B's second up
    local n="$1" kick="$2" before after a_after b_after kicked="-"
    hdr "phase $n: $( $kick && echo 'WITH helper restart' || echo 'without helper restart')"
    restart_system

    say "step 1: B up → down (B's network takes a bridge unit, then releases the bridge)"
    augur_in "$DIR_B" up || return 1
    augur_in "$DIR_B" down || true

    say "step 2: A up"
    augur_in "$DIR_A" up || return 1
    say "A gateway: $(gateway "$NET_A")"
    show_bridges
    before="$(probe "$CTR_A")"
    say "A probe before B's second up: HTTP ${before:-000}"

    if $kick; then
        say "step 3: restart B's network helper"
        if kick_helper_b; then kicked="ok"; else kicked="FAILED"; fi
    fi

    say "step 4: B up again"
    augur_in "$DIR_B" up || say "(continuing: B's up failed)"
    say "A gateway: $(gateway "$NET_A")   B gateway: $(gateway "$NET_B")"
    show_bridges
    a_after="$(probe "$CTR_A")"; b_after="$(probe "$CTR_B")"
    say "A probe after B's second up: HTTP ${a_after:-000}"
    say "B probe after B's second up: HTTP ${b_after:-000}"

    after="bridges=$(bridge_count) A_before=${before:-000} A_after=${a_after:-000} B=${b_after:-000} kick=${kicked}"
    if alive "$CTR_A"; then after="A SURVIVED  ($after)"; else after="A BROKE     ($after)"; fi
    if [[ "$n" == 1 ]]; then RES_1="$after"; else RES_2="$after"; fi

    augur_in "$DIR_A" down || true
    augur_in "$DIR_B" down || true
}

# ── main ─────────────────────────────────────────────────────────────────────
hdr "setup"
say "project A: $DIR_A  (net $NET_A)"
say "project B: $DIR_B  (net $NET_B)"
say "results:   $RESULTS_DIR"

# Create both containers/networks once so the phases only exercise up/down on persisted ones,
# exactly like day-to-day use. The image is built here if it is missing.
augur_in "$DIR_A" up || fail "initial up of A failed"
augur_in "$DIR_A" down || true
augur_in "$DIR_B" up || fail "initial up of B failed"
augur_in "$DIR_B" down || true

run_phase 1 false || RES_1="${RES_1:-ABORTED (see log)}"
run_phase 2 true  || RES_2="${RES_2:-ABORTED (see log)}"

hdr "summary"
echo "  phase 1 (no restart):   ${RES_1}"
echo "  phase 2 (with restart): ${RES_2}"
echo
case "$RES_1|$RES_2" in
    "A BROKE"*"|A SURVIVED"*)
        echo "  → Reproduced, and restarting B's helper prevented it: the augur-side fix is viable." ;;
    "A BROKE"*"|A BROKE"*)
        echo "  → Reproduced, but the helper restart did NOT prevent it: need another approach." ;;
    "A SURVIVED"*)
        echo "  → Not reproduced: the outage likely has a different cause (or the bug needs other timing)." ;;
    *)
        echo "  → Inconclusive; check $LOG." ;;
esac
