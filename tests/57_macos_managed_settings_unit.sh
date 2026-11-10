#!/usr/bin/env bash
# Tier 1 — the macOS base VM's managed agent policy is installed by ONE root script over ONE ssh
# connection, with nothing staged in the guest user's home, and replaces the whole policy directory
# (runs anywhere; nothing is cloned, booted or SSH'd: the "guest" is a local shell run against a
# sandboxed directory).
#
# A file staged in the guest user's home and moved into /Library by a second, privileged call
# could be swapped by any process of that user in between, and an old policy directory edited in
# place keeps whatever a non-root user put in or on it. Either way the build would save that state
# into the base VM every clone inherits. Pinned here, through the REAL
# install_macos_managed_settings, macos_managed_settings_swap_sh, macos_run_root_script and
# ssh_macos, with only `ssh` stubbed:
#   • one ssh connection, whose remote command stages nothing (no `cat >`, no home path); the guest
#     user's home is left empty;
#   • the admin password is on no argv, in no output and in no written file, NOPASSWD sudo or not;
#   • the payload arrives byte-exact (it travels base64-encoded), including quotes, `$`,
#     backslashes, NUL and control bytes, the root script's marker line and its own text, with or
#     without trailing newlines;
#   • the result is a fresh directory, root:wheel (asked of chown) 755, holding only the policy file,
#     root:wheel 644; `chmod -N` (strip any ACL) is run on the fresh directory, the file and the
#     quarantine; nothing is left next to it;
#   • whatever was at the directory's path is replaced and gone: a 777 directory with entries, a
#     hard-linked entry, a root-owned `.managed-settings.backup/`, a directory at the target path, a
#     regular file at the directory's path, a symlink to a directory (whose target is untouched);
#   • the old one is moved into a 700 quarantine under /var/root, which is then removed; nothing
#     the guest printed is shown on success;
#   • the parent (/Library/Application Support) must be a real directory owned by root and not
#     writable by group or others, with no ACL or one of deny entries only, whether `ls -lden`
#     names the principal by UUID (as macOS does) or type:name (an allow entry or an
#     unparsable line is refused; the fresh directory gets no ACL at all); otherwise nothing is
#     created or moved;
#   • ANY failure (a failing generator, no stored password or SSH transport, a wrong password, a
#     failed chown, `chmod -N`, quarantine or move) returns 1 with the reason, leaves the old
#     directory as it was (put back from the quarantine when it was already moved aside, also when
#     the swapped-in directory fails its check) and no fresh one or empty quarantine behind; when
#     putting it back fails, the reason names where it is and the quarantine keeps it;
#   • a quarantine that cannot be removed once the new policy is live is only a warning naming it;
#   • success needs status 0 AND the script's AUGUR_POLICY_LIVE report as its last line; an `ls -le`
#     that fails or prints nothing is refused (fail closed); a deny ACL entry that denies reading is
#     refused; entries discarded with an old directory are named, base64 on the wire, so a name
#     with a newline and a report line forges nothing;
#   • verify_macos_managed_settings passes on the policy as installed (other files, a deny-only ACL
#     on the directory allowed) and names what differs otherwise: the file overwritten, loosened,
#     removed, hard-linked or given any ACL, the directory loosened, replaced by a symlink or given
#     an allow ACL entry or one denying reading; a mismatch it found and a check that could not run
#     (no password, no transport, a failed ssh) are reported apart;
#
# How the guest runs: the stub runs the remote command in an unprivileged user + mount namespace
# (`unshare -rm`, which maps this user to root, so files the test creates are root-owned). In it, a
# recording `chown` is bind-mounted over /usr/sbin (the script's chown path), a recording `chmod` is
# overlaid on /usr/bin (it plays macOS's `chmod -N` and passes every other call to the real one),
# with `mv` and `rm` that can be made to fail or race (and otherwise run the real ones), a
# test directory is mounted over /var (so /var/root is the test's), and `bash --posix` over /bin/sh.
# The script's own absolute tool paths are used and its bytes are never rewritten. `sudo` is a
# stand-in on PATH that reads the password line one byte at a time and refuses a wrong one
# (SUDO_NOPASSWD=1: reads nothing, as with a NOPASSWD grant).
# Accepted trade-off: that is bash 5 in POSIX mode, not macOS's /bin/sh (bash 3.2 in sh mode), GNU
# ls, mv and base64, not macOS's, and no real ACL (the `ls -le` check is skipped by a GNU ls); the
# live check on a Mac covers those. Hosts without unprivileged namespaces and overlayfs (macOS
# itself) skip the tiers that run the script.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
exec </dev/null

# Boot-proofing, as in tests/38: the resolved $VM_CLI can never be a real augur-vm.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

HOME="$TMPD/home"; mkdir -p "$HOME"
# shellcheck disable=SC2034  # read by the sourced augur functions
AUGUR_DIR="$TMPD/augur"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

SECRET='pW9+tEsT/sEcReT=='
mkdir -p "$AUGUR_DIR/vms/testvm"
macos_store_admin_password testvm "$SECRET"
# shellcheck disable=SC2034  # read by the sourced ssh wrappers: no key, so no -i/BatchMode opts
MACOS_SSH_KEY="$TMPD/no-such-key"
macos_ssh_host()      { echo "127.0.0.1"; }
macos_ssh_port()      { echo "22"; }
vm_known_hosts_file() { echo "$TMPD/known_hosts"; }

# The guest: its user's home, its /var (holding root's home), and the target under a sandboxed
# /Library (with a space, as the real path has one).
GUEST_HOME="$TMPD/guest-home"; mkdir -p "$GUEST_HOME"
GUEST_VAR="$TMPD/var"; ROOTHOME="$GUEST_VAR/root"
BASE="$TMPD/guest/Library/Application Support"
DSTDIR="$BASE/ClaudeCode"
DST="$DSTDIR/managed-settings.json"
agent_macos_managed_settings_path() { printf '%s\n' "$DST"; }
REAL_PAYLOAD="$TMPD/real-payload"; agent_managed_settings_json > "$REAL_PAYLOAD"
OUTSIDE="$TMPD/outside"                    # a directory outside the guest's policy tree

# ── The guest's tools ────────────────────────────────────────────────────────────────────────────
FAKEBIN="$TMPD/fakebin"; FAKESBIN="$TMPD/fakesbin"; FAKEUSRBIN="$TMPD/fakeusrbin"
mkdir -p "$FAKEBIN" "$FAKESBIN" "$FAKEUSRBIN"
cat > "$FAKEBIN/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -S ] || { echo "sudo stand-in: not -S" >&2; exit 1; }
while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; -*) shift ;; *) break ;; esac; done
if [ "$SUDO_NOPASSWD" != 1 ]; then
    IFS= read -r pw
    [ "$pw" = "$SUDO_WANT" ] || { echo "Sorry, try again." >&2; exit 1; }
fi
exec "$@"
EOF
cat > "$FAKESBIN/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CHOWNLOG"
[ "$CHOWN_FAILS" != 1 ]
EOF
REAL_CHMOD="$(readlink -f /usr/bin/chmod 2>/dev/null)"
if [[ "$REAL_CHMOD" == /usr/bin/* ]]; then cp "$REAL_CHMOD" "$TMPD/real-chmod"; REAL_CHMOD="$TMPD/real-chmod"; fi
cat > "$FAKEUSRBIN/chmod" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$CHMODLOG"
if [ "\$1" = -N ]; then [ -z "\$CHMOD_N_NOISE" ] || echo "chmod: noise on stderr" >&2; [ "\$CHMOD_N_FAILS" != 1 ]; exit; fi
exec '$REAL_CHMOD' "\$@"
EOF
# The real `mv` and `rm` behind the recording ones below (copied out when /usr/bin holds the binary
# itself, which the overlay hides).
real_tool() {
    local t; t="$(readlink -f "/usr/bin/$1" 2>/dev/null)"
    if [[ "$t" == "/usr/bin/$1" ]]; then cp "$t" "$TMPD/real-$1"; t="$TMPD/real-$1"; fi
    printf '%s' "$t"
}
REAL_MV="$(real_tool mv)"; REAL_RM="$(real_tool rm)"; REAL_LS="$(real_tool ls)"
# `mv` that fails when its destination matches MV_FAIL_DEST (only the first time if MV_FAIL_ONCE
# names a flag file), and, after moving the fresh directory to exactly MV_RACE_DEST, drops an
# intruder in it.
cat > "$FAKEUSRBIN/mv" <<EOF
#!/bin/sh
for d; do :; done
if [ -n "\$MV_FAIL_DEST" ]; then
    case "\$d" in \$MV_FAIL_DEST)
        if [ -z "\$MV_FAIL_ONCE" ] || [ ! -e "\$MV_FAIL_ONCE" ]; then
            [ -z "\$MV_FAIL_ONCE" ] || : > "\$MV_FAIL_ONCE"; echo "mv: injected failure" >&2; exit 1
        fi ;;
    esac
fi
'$REAL_MV' "\$@" || exit
case "\$1" in */.augur-policy.*) ;; *) exit 0 ;; esac
if [ -n "\$MV_RACE_DEST" ] && [ "\$d" = "\$MV_RACE_DEST" ]; then : > "\$d/intruder"; fi
EOF
# `rm` that fails on the quarantine when RM_QUAR_FAILS=1.
cat > "$FAKEUSRBIN/rm" <<EOF
#!/bin/sh
if [ "\$RM_QUAR_FAILS" = 1 ]; then
    for a; do case "\$a" in /var/root/.augur-quarantine.*) echo "rm: injected failure" >&2; exit 1 ;; esac; done
fi
exec '$REAL_RM' "\$@"
EOF
chmod +x "$FAKEBIN/sudo" "$FAKESBIN/chown" "$FAKEUSRBIN/chmod"
# `ls` that plays macOS's `-lden` (GNU ls has no -e): the `-ldn` line, and for a path matching the
# pattern LS_ACL_PATH, `+` on its mode (in `-ldn` too) and the ACL lines LS_ACL_LINES after it. For a
# path matching LS_LDEN_FAILS, `-lden` fails; for one matching LS_LDEN_EMPTY, it prints nothing.
cat > "$FAKEUSRBIN/ls" <<EOF
#!/bin/sh
if [ "\$1" = -ldn ] || [ "\$1" = -lden ]; then
    if [ "\$1" = -lden ]; then
        if [ -n "\$LS_LDEN_FAILS" ]; then case "\$2" in \$LS_LDEN_FAILS) echo "ls: injected failure" >&2; exit 1 ;; esac; fi
        if [ -n "\$LS_LDEN_EMPTY" ]; then case "\$2" in \$LS_LDEN_EMPTY) exit 0 ;; esac; fi
    fi
    out="\$('$REAL_LS' -ldn "\$2")" || exit
    if [ -n "\$LS_ACL_PATH" ]; then
        case "\$2" in \$LS_ACL_PATH)
            printf '%s+ %s\\n' "\${out%% *}" "\${out#* }"
            [ "\$1" = -ldn ] || printf '%s\\n' "\$LS_ACL_LINES"
            exit 0 ;;
        esac
    fi
    printf '%s\\n' "\$out"
    exit 0
fi
exec '$REAL_LS' "\$@"
EOF
chmod +x "$FAKEUSRBIN/mv" "$FAKEUSRBIN/rm" "$FAKEUSRBIN/ls"
BASH_BIN="$(readlink -f "$(command -v bash)")"
SH_TARGET="$(readlink -f /bin/sh)"; SH_WRAP=""
if [[ "$SH_TARGET" != "$BASH_BIN" ]]; then
    SH_WRAP="$TMPD/sh-as-bash-posix"
    printf '#!%s\nexec -a sh %s --posix "$@"\n' "$BASH_BIN" "$BASH_BIN" > "$SH_WRAP"; chmod +x "$SH_WRAP"
fi
# The mounts that make the guest (see the header), then $1 under /bin/sh.
GUEST_MOUNTS='mount --bind "$1" /usr/sbin && mount -t overlay overlay -o lowerdir="$2":/usr/bin /usr/bin \
    && mount --bind "$3" /var && { [ -z "$4" ] || mount --bind "$4" "$5"; } && exec /bin/sh -c "$6"'
# NS_ARGS: -rm maps this user to root. With -c -m --keep-caps it maps this user to itself, keeping the
# capabilities the mounts need, so what the root script creates is NOT root-owned, as when a chown
# does not take.
NS_ARGS=(-rm)
in_guest() {   # in_guest CMD — run CMD as the guest, with this function's stdin
    unshare "${NS_ARGS[@]}" "$BASH_BIN" -c "$GUEST_MOUNTS" _ "$FAKESBIN" "$FAKEUSRBIN" "$GUEST_VAR" "$SH_WRAP" "$SH_TARGET" "$1"
}
mkdir -p "$ROOTHOME"
CAN_RUN=0
if command -v unshare >/dev/null 2>&1 && [[ -d /usr/sbin && -d /var && -n "$REAL_CHMOD" ]] \
    && in_guest true </dev/null 2>/dev/null; then CAN_RUN=1; fi
SUDO_NOPASSWD=0; CHOWN_FAILS=0; CHMOD_N_FAILS=0; GUEST_PW="$SECRET"
MV_FAIL_DEST=""; MV_FAIL_ONCE=""; MV_RACE_DEST=""; RM_QUAR_FAILS=0; CHMOD_N_NOISE=""; LS_ACL_PATH=""; LS_ACL_LINES=""; LS_LDEN_FAILS=""; LS_LDEN_EMPTY=""

# The recording `ssh`: call N leaves its argv in $LOG/N.argv and its stdin in $LOG/N.stdin, then
# runs the remote command, fed exactly that stdin, as the guest.
LOG="$TMPD/ssh"; mkdir -p "$LOG"
CHOWNLOG="$TMPD/chown-calls"; CHMODLOG="$TMPD/chmod-calls"
ssh() {
    local n; n=$(( $(find "$LOG" -name '*.argv' | wc -l) + 1 ))
    printf '%s\n' "$@" > "$LOG/$n.argv"
    cat > "$LOG/$n.stdin"
    local cmd="${!#}"
    ( cd "$GUEST_HOME" && HOME="$GUEST_HOME" PATH="$FAKEBIN:$PATH" SUDO_WANT="$GUEST_PW" \
          SUDO_NOPASSWD="$SUDO_NOPASSWD" CHOWNLOG="$CHOWNLOG" CHOWN_FAILS="$CHOWN_FAILS" \
          CHMODLOG="$CHMODLOG" CHMOD_N_FAILS="$CHMOD_N_FAILS" CHMOD_N_NOISE="$CHMOD_N_NOISE" MV_FAIL_DEST="$MV_FAIL_DEST" MV_FAIL_ONCE="$MV_FAIL_ONCE" \
          MV_RACE_DEST="$MV_RACE_DEST" RM_QUAR_FAILS="$RM_QUAR_FAILS" LS_ACL_PATH="$LS_ACL_PATH" LS_ACL_LINES="$LS_ACL_LINES" \
          LS_LDEN_FAILS="$LS_LDEN_FAILS" LS_LDEN_EMPTY="$LS_LDEN_EMPTY" in_guest "$cmd" ) < "$LOG/$n.stdin"
}
reset() {
    rm -rf "$LOG"/* "$CHOWNLOG" "$CHMODLOG" "$TMPD/guest" "$OUTSIDE" "$ROOTHOME" "$TMPD/mv-once"
    mkdir -p "$LOG" "$BASE" "$OUTSIDE" "$ROOTHOME"
}
# has_line TEXT GLOB — some line of TEXT matches GLOB as a whole.
has_line() { local _l; while IFS= read -r _l; do [[ "$_l" == $2 ]] && return 0; done <<< "$1"; return 1; }
n_calls() { find "$LOG" -name '*.argv' | wc -l | tr -d ' '; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# install_with PAYLOAD-FILE — run the real install with agent_managed_settings_json printing that
# file's exact bytes; sets $out and $rc.
install_with() {
    PAYLOAD_FILE="$1"
    agent_managed_settings_json() { cat "$PAYLOAD_FILE"; }
    out="$( set -e; install_macos_managed_settings testvm 2>&1 )"; rc=$?
}

# check_install NAME PAYLOAD-FILE — every property of a successful install.
check_install() {
    local name="$1" pf="$2"
    eq "0" "$rc" "$name: returns 0"
    hasnt "$out" "Could not" "$name: no failure"
    hasnt "$out" "  | " "$name: no guest output is shown"
    eq "1" "$(n_calls)" "$name: one ssh connection"
    if [[ -f "$DST" && ! -L "$DSTDIR" ]] && cmp -s "$pf" "$DST"; then ok "$name: the payload arrived byte-exact"
    else fail "$name: the installed file differs from the payload" \
              "want [$(od -c "$pf" | head -n5)] got [$(od -c "$DST" 2>/dev/null | head -n5)]"; fi
    eq "644" "$(file_mode "$DST" 2>/dev/null)" "$name: mode 644"
    eq "755" "$(file_mode "$DSTDIR" 2>/dev/null)" "$name: the policy directory is mode 755"
    eq "$(basename "$DST")" "$(ls -A "$DSTDIR" 2>/dev/null)" "$name: the policy directory holds only the policy file"
    eq "$(basename "$DSTDIR")" "$(ls -A "$BASE")" "$name: nothing is left next to the policy directory"
    eq "" "$(ls -A "$ROOTHOME")" "$name: the quarantine under /var/root is removed"
    eq "" "$(ls -A "$GUEST_HOME")" "$name: nothing is staged in the guest user's home"
    local ch cm
    ch="$(cat "$CHOWNLOG" 2>/dev/null)"; cm="$(cat "$CHMODLOG" 2>/dev/null)"
    [[ "$ch" == "root:wheel $BASE/.augur-policy."*$'\n'"root:wheel $BASE/.augur-policy."*"/managed-settings.json" ]] \
        && ok "$name: chown root:wheel on the fresh directory, then on the policy file in it" \
        || fail "$name: chown calls" "[$ch]"
    [[ "$cm" == *"-N $BASE/.augur-policy."* ]] && ok "$name: chmod -N on the fresh directory" || fail "$name: no chmod -N on the fresh directory" "[$cm]"
    has_line "$cm" "-N $BASE/.augur-policy.*/managed-settings.json" && ok "$name: chmod -N on the policy file" || fail "$name: no chmod -N on the policy file" "[$cm]"
    [[ "$cm" == *"700 /var/root/.augur-quarantine."* && "$cm" == *"-N /var/root/.augur-quarantine."* ]] \
        && ok "$name: the quarantine is a 700 directory under /var/root, ACL stripped" || fail "$name: quarantine" "[$cm]"
    if grep -rqF -- "$SECRET" "$LOG"/*.argv; then fail "$name: the admin password is on an ssh argv"
    else ok "$name: the admin password is on no ssh argv"; fi
    hasnt "$out" "$SECRET" "$name: the admin password is not in the output"
    if grep -qF -- "$SECRET" "$DST" 2>/dev/null; then fail "$name: the admin password is in the installed file"
    else ok "$name: the admin password is not in the installed file"; fi
    local argv; argv="$(cat "$LOG/1.argv")"
    hasnt "$argv" "cat > " "$name: the remote command writes no file before sudo"
    hasnt "$argv" "/Users/" "$name: the remote command names no home path"
    has "$argv" "sudo -S -k -p ''" "$name: the root script runs under one sudo -S -k"
}

# check_untouched NAME — a failed install: rc 1, the old policy directory as it was, nothing left.
check_untouched() {
    local name="$1"
    eq "1" "$rc" "$name: returns 1 (build/update stop)"
    has "$out" "Could not install the managed" "$name: the error says so"
    hasnt "$out" "$SECRET" "$name: the admin password is not in the output"
    eq "old" "$(cat "$DST" 2>/dev/null)" "$name: the old policy is still in place"
    eq "$(basename "$DSTDIR")" "$(ls -A "$BASE")" "$name: no fresh directory is left next to it"
}

section "Tier 1 — failures before any connection are fatal"
agent_managed_settings_json() { printf '{"env":'; return 1; }
reset; out="$( set -e; install_macos_managed_settings testvm 2>&1 )"; rc=$?
eq "1" "$rc" "failing generator: returns 1"
has "$out" "Could not produce the managed" "failing generator: says so"
eq "0" "$(n_calls)" "failing generator: nothing is sent to the guest"
E="$TMPD/empty"; : > "$E"
reset; install_with "$E"
eq "1" "$rc" "empty payload: returns 1"
eq "0" "$(n_calls)" "empty payload: nothing is sent to the guest"
agent_managed_settings_json() { cat "$REAL_PAYLOAD"; }
reset; out="$( set -e; install_macos_managed_settings nocredvm 2>&1 )"; rc=$?
eq "1" "$rc" "VM without a stored password: returns 1"
eq "0" "$(n_calls)" "VM without a stored password: no ssh connection is made"
has "$out" "no stored admin password" "VM without a stored password: augur's error says why"
hasnt "$out" "| VM 'nocredvm'" "VM without a stored password: augur's error is not shown as guest text"
reset; out="$( set -e; macos_ssh_host() { :; }; install_macos_managed_settings testvm 2>&1 )"; rc=$?
eq "1" "$rc" "no SSH transport: returns 1"
eq "0" "$(n_calls)" "no SSH transport: no ssh connection is made"
has "$out" "does not resolve" "no SSH transport: augur's error says why"
hasnt "$out" "| Cannot reach" "no SSH transport: augur's error is not shown as guest text"

section "Tier 1 — success is status 0 AND the script's live report"
fake_root_script() {   # fake_root_script RC STDOUT — the install against a root script that does only that
    FAKE_RC="$1"; FAKE_OUT="$2"
    out="$( macos_run_root_script() { MACOS_ROOT_SCRIPT_ERR="guest said this"; printf '%s' "$FAKE_OUT"; return "$FAKE_RC"; }
            install_macos_managed_settings testvm 2>&1 )"; rc=$?
}
fake_root_script 0 $'AUGUR_POLICY_LIVE\n'
eq "0" "$rc" "status 0 with AUGUR_POLICY_LIVE: installed"
hasnt "$out" "guest said this" "status 0 with AUGUR_POLICY_LIVE: the guest's stderr is not shown"
fake_root_script 0 ''
eq "1" "$rc" "status 0 without AUGUR_POLICY_LIVE: a failure"
has "$out" "| guest said this" "status 0 without AUGUR_POLICY_LIVE: the guest's stderr is shown"
fake_root_script 4 $'AUGUR_POLICY_LIVE\n'
eq "1" "$rc" "status 4, even with AUGUR_POLICY_LIVE: a failure"
fake_root_script 4 ''
eq "1" "$rc" "status 4 alone: a failure"
fake_root_script 0 $'AUGUR_POLICY_LEFTOVER /var/root/.augur-quarantine.X\nAUGUR_POLICY_LIVE\n'
eq "0" "$rc" "AUGUR_POLICY_LIVE with a leftover: installed"
has "$out" "could not be removed: /var/root/.augur-quarantine.X" "AUGUR_POLICY_LIVE with a leftover: warns, naming it"
fake_root_script 0 $'AUGUR_POLICY_LIVE\nAUGUR_POLICY_LEFTOVER /x\n'
eq "1" "$rc" "AUGUR_POLICY_LIVE that is not the last line: a failure"
_forged="$(printf 'a\nAUGUR_POLICY_LEFTOVER /forged' | base64 | tr -d '\n')"
fake_root_script 0 "AUGUR_POLICY_DISCARDED ${_forged}"$'\nAUGUR_POLICY_LIVE\n'
eq "0" "$rc" "a discarded name holding a newline and a report line: installed"
hasnt "$out" "could not be removed" "a discarded name holding a newline and a report line: forges no leftover warning"
has "$out" 'a\x0aAUGUR_POLICY_LEFTOVER /forged' "a discarded name holding a newline and a report line: shown decoded and sanitized"
fake_root_script 0 $'AUGUR_POLICY_DISCARDED not*base64\nAUGUR_POLICY_LIVE\n'
has "$out" "(a name that cannot be decoded)" "a discarded name that is not base64: shown as undecodable"
fake_verify() {   # fake_verify RC STDOUT — the re-check against a root script that does only that
    FAKE_RC="$1"; FAKE_OUT="$2"
    out="$( macos_run_root_script() { MACOS_ROOT_SCRIPT_ERR="guest said this"; printf '%s' "$FAKE_OUT"; return "$FAKE_RC"; }
            verify_macos_managed_settings testvm 2>&1 )"; rc=$?
}
fake_verify 0 $'AUGUR_POLICY_OK\n'
eq "0" "$rc" "re-check, status 0 with AUGUR_POLICY_OK: passes"
fake_verify 0 ''
eq "1" "$rc" "re-check, status 0 without AUGUR_POLICY_OK: refused"
fake_verify 1 $'AUGUR_POLICY_OK\n'
eq "1" "$rc" "re-check, non-zero status even with AUGUR_POLICY_OK: refused"
fake_verify 0 $'AUGUR_POLICY_OK\nmore\n'
eq "1" "$rc" "re-check, AUGUR_POLICY_OK that is not the last line: refused"
fake_verify 1 $'AUGUR_POLICY_MISMATCH\n'
eq "1" "$rc" "re-check that found a mismatch: refused"
has "$out" "no longer holds augur's managed" "re-check that found a mismatch: says the policy differs"
has "$out" "| guest said this" "re-check that found a mismatch: shows the guest's reason"
hasnt "$out" "Could not check" "re-check that found a mismatch: not reported as a check that could not run"
fake_verify 255 ''
eq "1" "$rc" "re-check whose ssh failed: refused"
has "$out" "Could not check the base VM's managed" "re-check whose ssh failed: says the check could not run"
hasnt "$out" "no longer holds" "re-check whose ssh failed: does not claim the policy differs"
fake_verify 1 ''
has "$out" "Could not check the base VM's managed" "re-check that failed without its report (e.g. a wrong password): says the check could not run"
out="$( set -e; verify_macos_managed_settings nocredvm 2>&1 )"; rc=$?
eq "1" "$rc" "re-check of a VM without a stored password: refused"
has "$out" "no stored admin password" "re-check of a VM without a stored password: augur's own error says why"
has "$out" "Could not check the base VM's managed" "re-check of a VM without a stored password: says the check could not run"
hasnt "$out" "no longer holds" "re-check of a VM without a stored password: does not claim the policy differs"
out="$( set -e; macos_ssh_host() { :; }; verify_macos_managed_settings testvm 2>&1 )"; rc=$?
has "$out" "Could not check the base VM's managed" "re-check with no SSH transport: says the check could not run"
hasnt "$out" "no longer holds" "re-check with no SSH transport: does not claim the policy differs"

section "Tier 1 — deny_only on real macOS 27 ls -lden output"
# Recorded verbatim on a macOS 27 guest: with -n, every ACL principal prints as a UUID
# (group:everyone is ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C). Run through POSIX sh, as the guest does
# (on a Mac, /bin/sh is the bash 3.2 the guest has).
REAL_DENY='-rw-r--r--+ 1 0  0  0 Nov  9 06:44 /var/root/augur-e2e-swap/acl-deny
 0: ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C deny delete'
REAL_INHERITED='drwx------+ 2 0  0  64 Nov  9 06:44 /var/root/augur-e2e-swap/inherit/.augur-policy.1xjdm8
 0: ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C inherited deny delete,file_inherit,directory_inherit'
deny_only_rc() {   # deny_only_rc LS-LDEN-OUTPUT — deny_only's status under /bin/sh
    /bin/sh -c "$(macos_policy_checks_sh)"'
deny_only "$1"' sh "$1" >/dev/null 2>&1; echo $?
}
eq "0" "$(deny_only_rc "$REAL_DENY")" "real deny entry with a UUID principal: accepted"
eq "0" "$(deny_only_rc "$REAL_INHERITED")" "real inherited deny entry with file_inherit,directory_inherit: accepted"
eq "0" "$(deny_only_rc "${REAL_DENY/ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C/group:everyone}")" "the same entry with a type:name principal: accepted"
eq "1" "$(deny_only_rc "${REAL_DENY/deny delete/allow delete}")" "real line made an allow entry: refused"
eq "1" "$(deny_only_rc "${REAL_INHERITED/inherited deny/inherited allow}")" "real inherited line made an allow entry: refused"
eq "1" "$(deny_only_rc "${REAL_DENY/deny delete/deny delete,readsecurity}")" "real line that also denies readsecurity: refused"
eq "1" "$(deny_only_rc "${REAL_INHERITED/delete,file_inherit/delete,list,file_inherit}")" "real inherited line that also denies list: refused"
eq "1" "$(deny_only_rc "${REAL_DENY/CDEF0000000C/CDEF0000000Z}")" "a principal that is UUID-shaped but not hex: refused"
eq "1" "$(deny_only_rc "${REAL_DENY/ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C/everyone}")" "a principal that is neither a UUID nor type:name: refused"
eq "1" "$(deny_only_rc "${REAL_DENY/ 0: / 0:}")" "a real line with its fields run together: refused"

if (( ! CAN_RUN )); then
    skip "the root script, run as the guest" "no unprivileged user+mount namespaces with overlayfs here"
    finish; exit $?
fi

section "Tier 1 — the guest (control)"
_probe="$( in_guest 'echo "$BASH_VERSION"; set -o | grep posix; /bin/chmod -N /nonexistent && echo chmod-N-ok; ls -A /var' 2>&1 )"
if [[ -n "$(sed -n 1p <<< "$_probe")" && "$_probe" =~ posix[[:space:]]+on ]]; then ok "the stub's /bin/sh is bash with POSIX mode on"
else fail "the stub's /bin/sh is not bash in POSIX mode" "[$_probe]"; fi
has "$_probe" "chmod-N-ok" "the stub's /bin/chmod takes -N"
has "$_probe" "root" "the stub's /var is the test's"

section "Tier 1 — a fresh install"
reset; install_with "$REAL_PAYLOAD"
check_install "real payload" "$REAL_PAYLOAD"
eq "$SECRET" "$(head -n1 "$LOG/1.stdin")" "real payload: the admin password is the first line of ssh's stdin"
eq "$MACOS_ROOT_SCRIPT_BEGIN" "$(sed -n 2p "$LOG/1.stdin")" "real payload: the root script's marker follows it"
hasnt "$(cat "$LOG/1.stdin")" "DISABLE_AUTOUPDATER" "real payload: the JSON is not on the wire as text (base64)"

CHMOD_N_NOISE=1; reset; install_with "$REAL_PAYLOAD"; CHMOD_N_NOISE=""
check_install "the guest prints on stderr while succeeding (not shown)" "$REAL_PAYLOAD"
hasnt "$out" "noise on stderr" "the guest prints on stderr while succeeding: none of it is shown"

section "Tier 1 — a hostile payload"
H="$TMPD/hostile"
{
    printf '%s\n' "{\"a\":'single' \"double\" \$HOME \${HOME} \$(id) \`id\` \\\\ \\n \\\$ \\"
    printf '%s\n' "$MACOS_ROOT_SCRIPT_BEGIN" "SCRIPT" "'"
    macos_managed_settings_swap_sh          # the root script's own text
    printf '%s\n' "exit 0" "exit 1" "\"}"
    printf 'ctl:\001\033[31m nul:\000 utf8:\303\251 '
    printf 'no trailing newline: end'
} > "$H"
has "$(tr -d '\000' < "$H")" '/usr/bin/base64 --decode' "hostile payload holds the root script's own text (control)"
reset; install_with "$H"
check_install "hostile payload" "$H"
for nl in 1 3; do
    T="$TMPD/trailing-$nl"; { cat "$H"; for (( i = 0; i < nl; i++ )); do printf '\n'; done; } > "$T"
    reset; install_with "$T"
    check_install "hostile payload + $nl trailing newline(s)" "$T"
done
SUDO_NOPASSWD=1; reset; install_with "$H"; SUDO_NOPASSWD=0
check_install "NOPASSWD sudo (the password line is discarded, never run)" "$H"

section "Tier 1 — whatever was at the policy directory's path is replaced, and gone"
reset; mkdir -p "$DSTDIR/sub"; chmod 777 "$DSTDIR" "$DSTDIR/sub"
printf 'old\n' > "$DST"; printf '{"mcpServers":{"x":{}}}\n' > "$DSTDIR/managed-mcp.json"; printf 'x\n' > "$DSTDIR/sub/deep"
install_with "$REAL_PAYLOAD"
check_install "a 777 directory with entries" "$REAL_PAYLOAD"
reset; mkdir -p "$DSTDIR"; printf 'outside\n' > "$OUTSIDE/file"; ln "$OUTSIDE/file" "$DSTDIR/managed-mcp.json"
install_with "$REAL_PAYLOAD"
check_install "a hard-linked entry" "$REAL_PAYLOAD"
eq "outside" "$(cat "$OUTSIDE/file")" "a hard-linked entry: the file it links to is untouched"
eq "1" "$(stat -c %h "$OUTSIDE/file" 2>/dev/null || stat -f %l "$OUTSIDE/file")" "a hard-linked entry: the link in the policy directory is gone"
reset; mkdir -p "$DSTDIR/.managed-settings.backup"; printf 'b\n' > "$DSTDIR/.managed-settings.backup/x"
install_with "$REAL_PAYLOAD"
check_install "a root-owned .managed-settings.backup/ (discarded with the old directory, by design)" "$REAL_PAYLOAD"
reset; mkdir -p "$DST"; printf 'keep\n' > "$DST/inside"
install_with "$REAL_PAYLOAD"
check_install "a directory at the target path" "$REAL_PAYLOAD"
reset; printf 'a file\n' > "$DSTDIR"
install_with "$REAL_PAYLOAD"
check_install "a regular file at the directory's path" "$REAL_PAYLOAD"
reset; mkdir -p "$OUTSIDE/linked"; printf 'outside\n' > "$OUTSIDE/linked/managed-settings.json"; ln -s "$OUTSIDE/linked" "$DSTDIR"
install_with "$REAL_PAYLOAD"
check_install "a symlink to a directory" "$REAL_PAYLOAD"
eq "outside" "$(cat "$OUTSIDE/linked/managed-settings.json")" "a symlink to a directory: its target is untouched"
eq "managed-settings.json" "$(ls -A "$OUTSIDE/linked")" "a symlink to a directory: nothing is written into its target"
reset; ln -s "$OUTSIDE/missing" "$DSTDIR"
install_with "$REAL_PAYLOAD"
check_install "a dangling symlink" "$REAL_PAYLOAD"
[[ -e "$OUTSIDE/missing" ]] && fail "a dangling symlink: something was created at its target" || ok "a dangling symlink: nothing is created at its target"

section "Tier 1 — any failure in the guest is fatal, and leaves the old directory as it was"
old_policy() { reset; mkdir -p "$DSTDIR"; printf 'old\n' > "$DST"; }
GUEST_PW="some-other-password"; old_policy; install_with "$REAL_PAYLOAD"; GUEST_PW="$SECRET"
check_untouched "wrong password"
has "$out" "| Sorry, try again." "wrong password: sudo's own message is shown as guest text"
CHOWN_FAILS=1; old_policy; install_with "$REAL_PAYLOAD"; CHOWN_FAILS=0
check_untouched "failed chown"
has "$out" "| cannot make" "failed chown: the guest's reason is shown"
CHMOD_N_FAILS=1; old_policy; install_with "$REAL_PAYLOAD"; CHMOD_N_FAILS=0
check_untouched "failed chmod -N"
has "$out" "without an ACL" "failed chmod -N: the guest's reason is shown"
old_policy; rmdir "$ROOTHOME"; install_with "$REAL_PAYLOAD"
check_untouched "no /var/root for the quarantine"
has "$out" "| cannot create a quarantine directory in /var/root" "no /var/root: the guest's reason is shown"
MV_FAIL_DEST="/var/root/.augur-quarantine.*/old"; old_policy; install_with "$REAL_PAYLOAD"; MV_FAIL_DEST=""
check_untouched "the old directory cannot be moved aside"
has "$out" "| cannot move the old" "the old directory cannot be moved aside: the guest's reason is shown"
eq "" "$(ls -A "$ROOTHOME")" "the old directory cannot be moved aside: the empty quarantine is removed"

section "Tier 1 — the parent directory must be root's alone"
base_refused() {   # base_refused NAME — refused before anything is created, the old policy kept
    check_untouched "$1"
    has "$out" "is not a directory owned by root, unwritable by group and others, without an ACL" "$1: the guest's reason is shown"
    eq "" "$(cat "$CHOWNLOG" 2>/dev/null)" "$1: nothing is chowned"
    eq "" "$(ls -A "$ROOTHOME")" "$1: no quarantine is made"
}
old_policy; chmod 775 "$BASE"; install_with "$REAL_PAYLOAD"
base_refused "group-writable parent"
old_policy; chmod 757 "$BASE"; install_with "$REAL_PAYLOAD"
base_refused "other-writable parent"
old_policy; chmod 755 "$BASE"; chown "$(id -u):$(id -g)" "$BASE"
NS_ARGS=(-c -m --keep-caps); install_with "$REAL_PAYLOAD"; NS_ARGS=(-rm)
base_refused "parent not owned by root"
reset; mkdir -p "$OUTSIDE/realbase/ClaudeCode"; printf 'old\n' > "$OUTSIDE/realbase/ClaudeCode/managed-settings.json"
rmdir "$BASE"; ln -s "$OUTSIDE/realbase" "$BASE"
install_with "$REAL_PAYLOAD"
eq "1" "$rc" "symlinked parent: returns 1"
has "$out" "is not a directory owned by root" "symlinked parent: the guest's reason is shown"
eq "old" "$(cat "$OUTSIDE/realbase/ClaudeCode/managed-settings.json")" "symlinked parent: nothing is changed through it"
eq "ClaudeCode" "$(ls -A "$OUTSIDE/realbase")" "symlinked parent: nothing is created through it"
reset; mkdir -p "$BASE"; chmod 755 "$BASE"; install_with "$REAL_PAYLOAD"
check_install "a stock root-owned 755 parent (control)" "$REAL_PAYLOAD"
acl_parent() {   # acl_parent LINES — the parent shows an ACL with these lines
    LS_ACL_PATH="$BASE"; LS_ACL_LINES="$1"; old_policy; install_with "$REAL_PAYLOAD"; LS_ACL_PATH=""; LS_ACL_LINES=""
}
acl_parent ' 0: group:everyone deny delete'
rc_ok=$rc; out_ok="$out"
eq "0" "$rc_ok" "parent with a deny-only ACL: accepted"
if cmp -s "$REAL_PAYLOAD" "$DST"; then ok "parent with a deny-only ACL: the policy is installed"; else fail "parent with a deny-only ACL: no policy" "$out_ok"; fi
acl_parent $' 0: group:everyone deny delete\n 1: user:admin inherited deny add_file,add_subdirectory'
eq "0" "$rc" "parent with deny-only ACL entries, one inherited: accepted"
acl_parent ' 0: group:staff allow add_file'
base_refused "parent with an allow ACL entry"
acl_parent $' 0: group:everyone deny delete\n 1: group:staff inherited allow add_file'
base_refused "parent with deny entries and an inherited allow entry"
acl_parent 'garbage in the ACL listing'
base_refused "parent with an unparsable ACL line"
acl_parent ' 0: group:everyone deny'
base_refused "parent with an ACL line without permissions"
acl_parent ' 0: group:everyone deny search,list'
base_refused "parent with a deny entry for search,list (the agent could not read the policy)"
acl_parent ' 0: group:everyone deny read'
base_refused "parent with a deny entry for read"
acl_parent ' 0: group:everyone inherited deny delete,readattr'
base_refused "parent with an inherited deny entry that includes readattr"
acl_parent ' x: group:everyone deny delete'
base_refused "parent with an ACL line without an index"
acl_parent "$(sed -n 2p <<< "$REAL_DENY")"
eq "0" "$rc" "parent with macOS 27's real deny entry (UUID principal): accepted"
acl_parent "$(sed -n 2p <<< "$REAL_INHERITED")"
eq "0" "$rc" "parent with macOS 27's real inherited deny entry: accepted"
acl_parent ' 0: ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C allow add_file'
base_refused "parent with an allow entry for a UUID principal"
acl_parent ' 0: ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C inherited deny delete,readextattr,file_inherit,directory_inherit'
base_refused "parent with an inherited deny entry for a UUID principal that includes readextattr"
LS_ACL_PATH="$BASE/.augur-policy.*"; LS_ACL_LINES=' 0: group:everyone deny delete'; old_policy; install_with "$REAL_PAYLOAD"; LS_ACL_PATH=""; LS_ACL_LINES=""
check_untouched "fresh directory with even a deny-only ACL"
has "$out" "| the new policy is not root:wheel without an ACL" "fresh directory with even a deny-only ACL: refused (no ACL allowed there)"

section "Tier 1 — a failure after the old directory is moved aside puts it back"
old_tree() { old_policy; printf 'x\n' > "$DSTDIR/managed-mcp.json"; }
check_restored() {   # check_restored NAME
    check_untouched "$1"
    eq $'managed-mcp.json\nmanaged-settings.json' "$(ls -A "$DSTDIR" | LC_ALL=C sort)" "$1: the old directory is back, whole"
    eq "" "$(ls -A "$ROOTHOME")" "$1: the quarantine is removed after the restore"
}
MV_FAIL_DEST="$DSTDIR"; MV_FAIL_ONCE="$TMPD/mv-once"; old_tree; install_with "$REAL_PAYLOAD"; MV_FAIL_DEST=""; MV_FAIL_ONCE=""
check_restored "the new directory cannot be moved into place"
has "$out" "| cannot move the new policy directory to" "the new directory cannot be moved into place: the guest's reason is shown"
MV_RACE_DEST="$DSTDIR"; old_tree; install_with "$REAL_PAYLOAD"; MV_RACE_DEST=""
check_restored "the post-swap check fails"
has "$out" "is not exactly the new policy after the swap" "the post-swap check fails: the guest's reason is shown"
[[ -e "$DSTDIR/intruder" ]] && fail "the post-swap check fails: the new directory stayed live" || ok "the post-swap check fails: the new directory is not left live"
MV_RACE_DEST="$DSTDIR"; reset; install_with "$REAL_PAYLOAD"; MV_RACE_DEST=""
eq "1" "$rc" "the post-swap check fails with no old directory: returns 1"
[[ -e "$DSTDIR" ]] && fail "the post-swap check fails with no old directory: the new directory stayed live" \
    || ok "the post-swap check fails with no old directory: nothing is left at the path"
eq "" "$(ls -A "$ROOTHOME")" "the post-swap check fails with no old directory: the quarantine is removed"
MV_FAIL_DEST="$DSTDIR"; old_tree; install_with "$REAL_PAYLOAD"; MV_FAIL_DEST=""
eq "1" "$rc" "the old directory cannot be put back: returns 1"
has "$out" "| cannot put the old ${DSTDIR} back; it is at /var/root/.augur-quarantine." "the old directory cannot be put back: says so, and where it is"
_q="$(ls -A "$ROOTHOME")"
eq $'managed-mcp.json\nmanaged-settings.json' "$(ls -A "$ROOTHOME/$_q/old" 2>/dev/null | LC_ALL=C sort)" "the old directory cannot be put back: it is kept, whole, in the quarantine"

section "Tier 1 — only the cleanup failing is a warning, not a failure"
RM_QUAR_FAILS=1; old_tree; install_with "$REAL_PAYLOAD"; RM_QUAR_FAILS=0
eq "0" "$rc" "the quarantine cannot be removed: returns 0 (the policy is live)"
has "$out" "the old policy directory could not be removed" "the quarantine cannot be removed: the warning says so"
has "$out" "could not be removed: /var/root/.augur-quarantine." "the quarantine cannot be removed: the leftover is named"
if cmp -s "$REAL_PAYLOAD" "$DST"; then ok "the quarantine cannot be removed: the new policy is installed"; else fail "the quarantine cannot be removed: no new policy"; fi
eq "$(basename "$DST")" "$(ls -A "$DSTDIR")" "the quarantine cannot be removed: the live directory holds only the policy"

section "Tier 1 — an ACL check that cannot be read is refused"
LS_LDEN_FAILS="$BASE"; old_policy; install_with "$REAL_PAYLOAD"; LS_LDEN_FAILS=""
base_refused "parent whose ls -le fails"
LS_LDEN_EMPTY="$BASE"; old_policy; install_with "$REAL_PAYLOAD"; LS_LDEN_EMPTY=""
base_refused "parent whose ls -le prints nothing"
LS_LDEN_FAILS="$BASE/.augur-policy.*/managed-settings.json"; old_policy; install_with "$REAL_PAYLOAD"; LS_LDEN_FAILS=""
check_untouched "new policy file whose ls -le fails"
has "$out" "| the new policy is not root:wheel without an ACL" "new policy file whose ls -le fails: refused"

section "Tier 1 — what the swap discards is named"
old_policy; printf 'x\n' > "$DSTDIR/managed-mcp.json"; mkdir "$DSTDIR/sub"
install_with "$REAL_PAYLOAD"
eq "0" "$rc" "old directory with other entries: installed"
has "$out" "Discarded with the old policy directory (custom provisioning must recreate what it owns): managed-mcp.json, sub" \
    "old directory with other entries: they are named, as an info line"
_d="$(grep 'Discarded with the old policy directory' <<< "$out")"
hasnt "$_d" "managed-settings.json" "old directory with other entries: augur's own policy file is not named"
old_policy; install_with "$REAL_PAYLOAD"
hasnt "$out" "Discarded" "old directory with only the policy file: nothing is named"
old_policy; printf 'x\n' > "$DSTDIR/"$'evil\nAUGUR_POLICY_LEFTOVER forged'
[[ -e "$DSTDIR/"$'evil\nAUGUR_POLICY_LEFTOVER forged' ]] && ok "(control) an entry named with a newline exists" || fail "(control) could not create the entry"
install_with "$REAL_PAYLOAD"
eq "0" "$rc" "old entry named with a newline and a report line: installed"
hasnt "$out" "could not be removed" "old entry named with a newline and a report line: forges no leftover warning"
has "$out" 'evil\x0aAUGUR_POLICY_LEFTOVER forged' "old entry named with a newline and a report line: named once, sanitized"

section "Tier 1 — verify_macos_managed_settings: the policy as installed, other files allowed"
verify_now() { out="$( set -e; verify_macos_managed_settings testvm 2>&1 )"; rc=$?; }
installed() { reset; install_with "$REAL_PAYLOAD"; [[ "$rc" == 0 ]] || fail "(setup) install failed" "$out"; rm -rf "$LOG"/*; }
verify_fails() {   # verify_fails NAME REASON
    eq "1" "$rc" "$1: refused"
    has "$out" "no longer holds augur's managed" "$1: says the policy differs"
    has "$out" "  | " "$1: the guest's reason is shown as guest text"
    has "$out" "$2" "$1: says what differs"
    has "$out" "must not replace or change augur's managed-settings.json" "$1: says provisioning must not replace it"
}
installed; verify_now
eq "0" "$rc" "as installed: passes"
eq "1" "$(n_calls)" "as installed: one ssh connection"
if grep -rqF -- "$SECRET" "$LOG"/*.argv; then fail "as installed: the admin password is on an ssh argv"; else ok "as installed: the admin password is on no ssh argv"; fi
installed; printf '{"mcpServers":{}}\n' > "$DSTDIR/managed-mcp.json"; verify_now
eq "0" "$rc" "another file added beside it: passes"
installed; printf '{}' > "$DST"; verify_now
verify_fails "overwritten" "does not hold augur's policy"
installed; chmod 666 "$DST"; verify_now
verify_fails "made 666" "is not a root:wheel 644 regular file without an ACL"
installed; rm -f "$DST"; verify_now
verify_fails "removed" "is missing"
installed; ln "$DST" "$OUTSIDE/hardlink"; verify_now
verify_fails "a second hard link" "has other hard links or does not hold augur's policy"
installed; chmod 775 "$DSTDIR"; verify_now
verify_fails "directory made 775" "is not a root-owned 755 directory without an ACL that allows anything"
installed; mv "$DSTDIR" "$OUTSIDE/moved"; ln -s "$OUTSIDE/moved" "$DSTDIR"; verify_now
verify_fails "directory replaced by a symlink" "is not a root-owned 755 directory"
installed; LS_ACL_PATH="$DSTDIR"; LS_ACL_LINES=' 0: group:staff allow add_file'; verify_now; LS_ACL_PATH=""; LS_ACL_LINES=""
verify_fails "directory with an allow ACL entry" "without an ACL that allows anything"
installed; LS_ACL_PATH="$DSTDIR"; LS_ACL_LINES=' 0: group:everyone deny delete'; verify_now; LS_ACL_PATH=""; LS_ACL_LINES=""
eq "0" "$rc" "directory with a deny-only ACL: passes"
installed; LS_ACL_PATH="$DSTDIR"; LS_ACL_LINES="$(sed -n 2p <<< "$REAL_INHERITED")"; verify_now; LS_ACL_PATH=""; LS_ACL_LINES=""
eq "0" "$rc" "directory with macOS 27's real inherited deny entry (UUID principal): passes"
installed; LS_ACL_PATH="$DSTDIR"; LS_ACL_LINES=' 0: ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C allow add_file'; verify_now; LS_ACL_PATH=""; LS_ACL_LINES=""
verify_fails "directory with an allow entry for a UUID principal" "without an ACL that allows anything"
installed; LS_ACL_PATH="$DSTDIR"; LS_ACL_LINES=' 0: group:everyone deny list,search'; verify_now; LS_ACL_PATH=""; LS_ACL_LINES=""
verify_fails "directory with a deny entry for list,search" "or denies reading"
installed; LS_ACL_PATH="$DST"; LS_ACL_LINES=' 0: group:everyone deny delete'; verify_now; LS_ACL_PATH=""; LS_ACL_LINES=""
verify_fails "policy file with even a deny-only ACL" "is not a root:wheel 644 regular file without an ACL"
installed; LS_LDEN_FAILS="$DST"; verify_now; LS_LDEN_FAILS=""
verify_fails "policy file whose ls -le fails" "is not a root:wheel 644 regular file without an ACL"
installed; verify_now
hasnt "$out" "$SECRET" "the check prints no admin password"

finish
