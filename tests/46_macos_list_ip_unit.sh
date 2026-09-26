#!/usr/bin/env bash
# Tier 1 — `augur list --macos` shows a reachable address for every running VM (runs anywhere;
# nothing is booted — augur-vm is a stub script and gvproxy is a sleeping stand-in process).
#
# An egress-on VM's NIC is gvproxy's, so it never gets a DHCP lease and `augur-vm ip` finds
# nothing for it. list must instead show the gvproxy forward ssh_macos connects through — for
# ANY project's VM, not just the current one — and fall back to `augur-vm ip` for a VM without a
# live gvproxy (the base VM, an egress-off run).
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$TMPD"; }
trap cleanup EXIT

# augur-vm stub: three project VMs (two in other projects) and the base VM, all running. Only the
# base VM has a DHCP lease, as on a real host with egress on.
cat > "$TMPD/augur-vm" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) printf 'N NAME STATE\n1 augur-macos-app-aaaaaaaaaaaa running\n2 augur-macos-other-bbbbbbbbbbbb running\n3 augur-macos-base running\n4 augur-macos-old-cccccccccccc running\n' ;;
  ip)   [[ "$2" == "augur-macos-base" ]] && { echo 192.168.64.5; exit 0; }; exit 1 ;;
esac
EOF
chmod +x "$TMPD/augur-vm"
export AUGUR_VM_BIN="$TMPD/augur-vm"
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue
require_vz() { :; }                       # CI runs this on Linux
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"

# A gvproxy stand-in: argv carries the flags augur passes, the process just sleeps.
printf 'sleep 60\n' > "$TMPD/fake-gvproxy"
fake_gvproxy() {   # fake_gvproxy <pidfile-stem> <ssh-port>
    bash "$TMPD/fake-gvproxy" --listen-vfkit "unixgram://x" --ssh-port "$2" &
    PIDS+=("$!"); echo "$!" > "$AUGUR_PROXY_DIR/$1.gvproxy.pid"
}
fake_gvproxy app-aaaaaaaaaaaa 20286
fake_gvproxy other-bbbbbbbbbbbb 20417
# A stale pidfile (gvproxy gone) must not produce a forward address.
echo 999999 > "$AUGUR_PROXY_DIR/old-cccccccccccc.gvproxy.pid"

section "Tier 1 — macos_vm_gvproxy_fwd_port"
eq "20286" "$(macos_vm_gvproxy_fwd_port augur-macos-app-aaaaaaaaaaaa)"   "reads the forward port of a live gvproxy"
eq "20417" "$(macos_vm_gvproxy_fwd_port augur-macos-other-bbbbbbbbbbbb)" "…for another project's VM too"
macos_vm_gvproxy_fwd_port augur-macos-base >/dev/null
eq "1" "$?" "fails for a VM with no gvproxy pidfile (the base VM)"
macos_vm_gvproxy_fwd_port augur-macos-old-cccccccccccc >/dev/null
eq "1" "$?" "fails for a pidfile whose gvproxy is gone"
# The name mapping must match the pidfile start_gvproxy really writes for the current project.
WORKSPACE_DIR="$TMPD/My Project"
eq "$(gvproxy_pidfile)" "$AUGUR_PROXY_DIR/$(macos_project_vm | sed 's/^augur-macos-//').gvproxy.pid" \
    "the VM name minus 'augur-macos-' is the current project's gvproxy pidfile stem"

section "Tier 1 — cmd_list_macos"
out="$(cmd_list_macos 2>&1)"
has   "$out" "127.0.0.1:20286 (gvproxy fwd)" "an egress-on VM shows its gvproxy forward"
has   "$out" "127.0.0.1:20417 (gvproxy fwd)" "…including another project's VM"
has   "$out" "192.168.64.5"                  "a VM without gvproxy (the base VM) still shows its DHCP IP"
row="$(printf '%s\n' "$out" | grep 'augur-macos-old-')"
hasnt "$row" "gvproxy fwd"                   "a VM whose gvproxy is gone shows no forward…"
eq "-" "$(printf '%s' "$row" | sed $'s/\x1b\\[[0-9;]*m//g' | awk '{print $NF}')" \
    "…and falls back to augur-vm ip ('-' with no lease)"

finish
