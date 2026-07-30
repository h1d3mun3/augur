#!/usr/bin/env bash
# Tier 1 — per-project settings, host-side (`augur config`, project_settings_file). Runs anywhere;
# nothing is cloned, booted or really SSH'd, and every path this touches is inside a temp dir.
#
# WHY THE FEATURE EXISTS. `--share-refresh` and `--share-refresh-interval` are run-scoped, so an
# operator whose repo is big enough that one sweep outlasts the interval had to type the flag on every
# command, forever. The right value is a property of THE REPO (its changed-file count), so it is
# persisted per project — and HOST-side, under ~/.augur, because ./.augur/ lives inside the
# read-write share and a guest that can write its own refresh mode can switch off the mechanism that
# keeps the operator's view of that guest honest.
#
# WHAT THIS FILE PINS, and why each one is here rather than assumed:
#
#   • THE PATH SHAPE AND ITS KEYING. slug + workspace_path_hash, the key proxy_allowlist /
#     proxy_pidfile / project_conf_hash_file already use. A slug-only key is a GUARANTEED collision
#     for ~/work/app vs ~/archive/app, and here it would hand one project's refresh mode to an
#     unrelated — possibly hostile — same-basename sibling. tests/32 pins the same property for this
#     file alongside the egress state; it is pinned again here because both lists are hard-coded and a
#     reader of either should see it.
#   • UNREACHABILITY FROM THE GUEST — the whole security argument for the location. Asserted by
#     ENUMERATING both engines' mount argv and computing containment, not by grepping for a comment
#     that says so: the claim is about the code, and the code is four `--dir=` and six `-v` lines.
#   • EACH PRECEDENCE PAIR AS ITS OWN ARM. flag > file, file > env, env > default. One end-to-end arm
#     would pass on any ordering that happened to put the value under test on top.
#   • THE RAW WORKSPACE PATH ON LINE 2. `908d688ef046` tells a human nothing, and
#     ~/.augur/project-hashes/ already has that problem; that comment is the ONLY place the
#     hash → path mapping exists.
#   • WARN, NEVER SILENT. A rejected value must name the file, the value, what is used instead and a
#     remedy that works. A setting that has no effect and says nothing is #148 with a different cause.
#   • …AND NEVER FATAL. A broken settings file must leave `down`/`destroy`/`status --macos` working,
#     for the reason the dispatch tail states about a stale env var — and more sharply, because
#     `unset` fixes an export while this file survives `destroy --macos` by design.
#   • `--show` NAMING THE LAYER. With four layers the effective value alone cannot answer "why is my
#     edit not showing up"; the question is always which layer won.
#   • `destroy --macos` NOT REAPING IT. Operator intent about the project, not state describing the
#     VM. Driven for real, because "why does destroy not clean this up" is the review question.
#   • THE LAYER HAVING AN EFFECT AT ALL. Most arms below read `--show`, and `--show` is a report. The
#     gate arms drive share_refresh_enabled and the real sweep entry point, so a resolver wired only
#     into the printer would not pass — with a positive control in each case, because an arm that
#     asserts "nothing happened" against a fixture where nothing CAN happen tests nothing.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/lib.sh"
AUGUR="$REPO/augur"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Boot-proofing, as tests/30/34/35/36/37/41 do: point $VM_CLI at a path that cannot exist BEFORE the
# source, so no arm can ever reach a real augur-vm on this host.
export AUGUR_VM_BIN="$TMPD/no-such-augur-vm"
# The env LAYER is under test, so it must be this file's to control and not the runner's.
unset AUGUR_MACOS_REFRESH_INTERVAL
AUGUR_SOURCE_ONLY=1 source "$AUGUR"
set +e                                    # augur enables `set -e`; restore lib.sh assert-and-continue

# Sandbox everything. $HOME is the anchor: augur derives AUGUR_DIR from it with a plain assignment, so
# a subprocess given this HOME cannot reach the real ~/.augur.
HOME="$TMPD/home"; mkdir -p "$HOME/.config/gh"
AUGUR_DIR="$HOME/.augur"
AUGUR_PROXY_DIR="$TMPD/proxy"; mkdir -p "$AUGUR_PROXY_DIR"
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
WORKSPACE_DIR="$TMPD/ws"; mkdir -p "$WORKSPACE_DIR"
MACOS_SHARE="workspace-$(workspace_slug)"
VM=testvm
mkdir -p "$AUGUR_DIR/claude-projects/$VM" "$AUGUR_DIR/claude-agents/$VM" "$AUGUR_DIR/claude-profile"

SETTINGS="$(project_settings_file)"
COUT="$TMPD/cout"
wipe() { rm -rf "$(project_settings_dir)"; }

# A real augur, in a subprocess, from the sandbox workspace with the sandbox $HOME. SUBPROCESSES
# rather than the sourced functions for every PRECEDENCE arm, on purpose: the layering runs in the
# dispatch tail, so a resolver that was never CALLED there would leave in-process arms green while the
# shipped augur ignored the settings file completely.
#
# The output goes to a FILE and the status is this function's own, because `x="$(cfg …)"` runs cfg in a
# subshell — a first cut set CRC inside it and read an unbound variable outside.
cfg() {   # cfg <argv…> → returns augur's status; ANSI-stripped output via cout()
    ( cd "$WORKSPACE_DIR" && HOME="$HOME" bash "$AUGUR" "$@" ) > "$TMPD/raw" 2>&1
    local rc=$?
    sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"
    return $rc
}
cout() { cat "$COUT"; }
# `--show` prints "  <key>  <value>  (<layer>)". Both halves are read, always: an arm that checked
# only the value cannot tell the right answer from the right answer for the wrong reason.
val_of()   { printf '%s\n' "$2" | awk -v k="$1" '$1==k {print $2}'; }
label_of() { printf '%s\n' "$2" | awk -v k="$1" '$1==k {match($0,/\(.*\)$/); print substr($0,RSTART+1,RLENGTH-2)}'; }

section "the path: under ~/.augur, keyed per project PATH, with no side effect"

has "$SETTINGS" "$AUGUR_DIR/project-settings/" "the settings file lives under ~/.augur/project-settings/"
eq "$(workspace_slug)-$(workspace_path_hash).conf" "${SETTINGS##*/}" \
   "…and its leaf is <slug>-<workspace_path_hash>.conf, the proxy_allowlist/project_conf_hash_file key"
hasnt "$SETTINGS" "$WORKSPACE_DIR" "…and no part of it is inside the workspace (the guest-writable share)"
# The accessors must CREATE NOTHING: every read path calls them, `help --macos` included, so the
# `mkdir -p` that project_conf_hash_file has would scatter empty dirs for projects with no settings.
wipe
project_settings_file >/dev/null; project_settings_dir >/dev/null; project_settings_display >/dev/null
if [[ ! -d "$(project_settings_dir)" ]]; then ok "the path accessors create nothing (unlike project_conf_hash_file's mkdir)"
else fail "the path accessors create nothing" "reading a path must not be a write"; fi

# Two projects that share a BASENAME. The identical-slug assertion is what proves the hash is the
# disambiguator rather than an incidental difference in the directory names (tests/32's technique).
_orig_ws="$WORKSPACE_DIR"
mkdir -p "$TMPD/work/myapp" "$TMPD/archive/myapp"
WORKSPACE_DIR="$TMPD/work/myapp";    a_slug="$(workspace_slug)"; a_file="$(project_settings_file)"
WORKSPACE_DIR="$TMPD/archive/myapp"; b_slug="$(workspace_slug)"; b_file="$(project_settings_file)"
WORKSPACE_DIR="$_orig_ws"
eq "$a_slug" "$b_slug" "two same-basename projects produce the IDENTICAL slug…"
eq "myapp"   "$a_slug" "…and that shared slug is the basename, as everywhere else"
if [[ "$a_file" != "$b_file" ]]; then ok "…so the settings file still differs between them (the path hash separates them)"
else fail "the settings file must differ between two same-basename projects" "both = $a_file — one project's refresh mode would be read by an unrelated sibling"; fi

section "unreachable from the guest — enumerated, not asserted"

# THE ENTIRE SECURITY ARGUMENT for ~/.augur instead of ./.augur/, and it is checked by EXTRACTING
# every mount from the real argv and EVALUATING it, not by comparing against a hand-written list.
#
# The previous shape of this section was exactly that hand-written list, plus a blacklist of four
# literal source strings, and it was measurably blind to the breach it exists to catch. Adding
#     run_args+=(-v "${AUGUR_DIR}/project-settings:/settings")     # read-WRITE
# to cmd_up — the guest handed the file that decides whether the guest is being watched — left this
# file at 148/148, tests/32 at 62/62 and tests/11 at 108/108. So did `-v "${HOME}/.augur:/hostaugur"`.
# Three independent reasons, all of them structural: the `_mounts` array was hand-copied so a new
# share never entered the containment loop; the locatability arm was `-ge 9`, a LOWER bound that
# adding a mount keeps green; and the blacklist searched for `project_settings` (the underscore
# helper name) while the directory leaf is spelled `project-settings`, with a hyphen. A blacklist of
# spellings can only ever catch the spellings someone thought of.
#
# So: extract, evaluate, and test containment on the RESULT. A share added later is checked whether
# or not anyone remembers this file — either it evaluates to a path this loop tests, or it does not
# evaluate to an absolute path at all, which is itself a failure below.
#
# The LOCALS cmd_up computes have to be supplied here, and that much is unavoidably hand-written —
# but it is the VALUES of four variables, not the SET of mounts, which is the part that was wrong.
project_vm="$VM"
host_hist_dir="$AUGUR_DIR/$(agent_state_host_subdir)/$(workspace_slug)-$(workspace_path_hash)"
host_agents_dir="$AUGUR_DIR/$(agent_state_agents_host_subdir)/$(workspace_slug)-$(workspace_path_hash)"
host_profile_dir="$AUGUR_DIR/$(agent_profile_host_subdir)"
WORKSPACE_MOUNT="$(make_workspace_mount)"

# macOS: `--dir="<share-name>:<host-path>[:ro]"`. Container: `-v "<host-path>:<guest-path>[:ro]"`.
# The host path is field 2 of the first, field 1 of the second — after evaluation, so the colons that
# matter are the ones in the concrete string.
_dir_src="$(grep -E '^[[:space:]]*--dir="' "$AUGUR" | sed -e 's/^[[:space:]]*--dir="//' -e 's/"[[:space:]]*\\*[[:space:]]*$//')"
# `-v "` is matched ANYWHERE on the line, not just at the start: one of the six is guarded
# (`[[ -f "$HOME/.gitconfig" ]] && run_args+=(-v …)`), and an anchored pattern missed it — which is
# the same class of near-miss this section was rewritten to stop relying on. `command -v` is the one
# false positive that shape picks up, and it is excluded by name.
_v_src="$(grep -E -- '(^|[[:space:]]|\()-v "' "$AUGUR" | grep -v 'command -v' | grep -v '^[[:space:]]*#' \
          | sed -e 's/^.*-v "//' -e 's/")[[:space:]]*$//' -e 's/"[[:space:]]*$//')"
_n_dir="$(printf '%s\n' "$_dir_src" | grep -c .)"
_n_v="$(printf '%s\n' "$_v_src" | grep -c .)"
# EQUALITY, not a lower bound. Adding a share now fails here as well as in the containment loop, so
# the count is a second, independent tripwire rather than something a new mount slides under. These
# two numbers are the ONLY thing in this section a developer adding a legitimate share has to touch,
# and changing them is a deliberate act that puts the new path through the loop below.
eq "4" "$_n_dir" "the macOS argv is 4 \`--dir=\` shares (extracted from $AUGUR, not hand-copied)"
eq "6" "$_n_v"   "…and the container argv is 6 \`-v\` mounts"

_reach=0; _bad_eval=""; _n_mounts=0
_check_host_path() {   # $1 = evaluated host path, $2 = the source expression it came from
    _n_mounts=$((_n_mounts + 1))
    # A path that did not evaluate to an absolute path means a new mount referenced something this
    # fixture does not define — the one way an added share could slip past the containment test with
    # an empty string. It is a FAILURE, not a skip.
    case "$1" in /*) ;; *) _bad_eval="${_bad_eval}[$2 → '$1'] " ;; esac
    # Containment needs the `/` boundary: a bare string prefix would call ~/.augur-other a parent of
    # ~/.augur/x. Both directions are tested — the mount being the file, and the mount CONTAINING it.
    if [[ "$SETTINGS" == "$1" || "$SETTINGS" == "$1"/* ]]; then _reach=1; fi
}
while IFS= read -r _e; do
    [[ -n "$_e" ]] || continue
    eval "_x=\"$_e\""                     # the share as cmd_up_macos really builds it
    _check_host_path "$(printf '%s' "$_x" | cut -d: -f2)" "$_e"
done <<< "$_dir_src"
while IFS= read -r _e; do
    [[ -n "$_e" ]] || continue
    eval "_x=\"$_e\""                     # the mount as cmd_up really builds it
    _check_host_path "$(printf '%s' "$_x" | cut -d: -f1)" "$_e"
done <<< "$_v_src"

eq "10" "$_n_mounts" "every one of the 10 extracted mounts evaluated to a host path"
if [[ -z "$_bad_eval" ]]; then ok "…and every one of them is ABSOLUTE (a mount that did not evaluate cannot pass by being empty)"
else fail "a mount argv did not evaluate to an absolute host path" "$_bad_eval — add its variable to this fixture, or the containment test below is vacuous for it"; fi
if [[ $_reach -eq 0 ]]; then ok "the settings file is inside NONE of the ${_n_mounts} host paths either engine shares"
else fail "the settings file is reachable from a guest" "a guest could then switch off the mechanism that keeps the operator's view of it honest"; fi
# The same computation for ~/.augur ITSELF and for $HOME, because the file is only as unreachable as
# its parents: `-v "${HOME}/.augur:/hostaugur"` exposes it without ever naming it.
for _parent in "$AUGUR_DIR" "$HOME"; do
    _preach=0
    while IFS= read -r _e; do
        [[ -n "$_e" ]] || continue
        eval "_x=\"$_e\""; _p="$(printf '%s' "$_x" | cut -d: -f2)"
        if [[ "$_parent" == "$_p" || "$_parent" == "$_p"/* ]]; then _preach=1; fi
    done <<< "$_dir_src"
    while IFS= read -r _e; do
        [[ -n "$_e" ]] || continue
        eval "_x=\"$_e\""; _p="$(printf '%s' "$_x" | cut -d: -f1)"
        if [[ "$_parent" == "$_p" || "$_parent" == "$_p"/* ]]; then _preach=1; fi
    done <<< "$_v_src"
    if [[ $_preach -eq 0 ]]; then ok "…and neither engine shares ${_parent#"$TMPD"} itself, which would expose it without naming it"
    else fail "a mount shares ${_parent}" "every file augur keeps host-side is then guest-readable"; fi
done
# The last line of defence for the workspace share: a $WORKSPACE_DIR that would swallow ~/.augur is
# refused outright, so there is no `cd` that makes this file visible through the project mount. The
# directories are created first — require_safe_workspace compares PHYSICAL paths, and a workspace that
# does not exist falls back to the logical one, which on a /var → /private/var host compares unequal.
mkdir -p "$(project_settings_dir)"
for _ws in "$HOME" "$AUGUR_DIR" "$(project_settings_dir)" "/"; do
    _sv="$WORKSPACE_DIR"; WORKSPACE_DIR="$_ws"
    ( require_safe_workspace ) >/dev/null 2>&1; _grc=$?
    WORKSPACE_DIR="$_sv"
    if [[ $_grc -ne 0 ]]; then ok "require_safe_workspace refuses a workspace at ${_ws#"$TMPD"} (it would expose the file)"
    else fail "require_safe_workspace accepted a workspace containing the settings file" "ws=$_ws"; fi
done

section "\`augur config\` writes the file, with the RAW workspace path in it"

wipe
cfg config --share-refresh attach; CRC=$?
eq "0" "$CRC" "\`augur config --share-refresh attach\` succeeds"
if [[ -f "$SETTINGS" ]]; then ok "…and creates the settings file"
else fail "augur config creates the settings file" "$(cout)"; fi
has "$(cout)" "attach" "…and says what it set"
# LINE 2, exactly. The filename holds a 12-char hash and nothing else, so without this comment an
# operator listing ~/.augur/project-settings/ cannot get from a hash back to a project. Asserted on
# the LINE and not with a substring search of the whole file, because the point is that it is the
# readable header — a path buried anywhere would satisfy a grep.
_l2="$(sed -n '2p' "$SETTINGS")"
has "$_l2" "$WORKSPACE_DIR" "line 2 carries the RAW workspace path (the hash alone identifies nothing)"
has "$_l2" "#"              "…as a comment, so it is never parsed back as a setting"
has "$(sed -n '1p' "$SETTINGS")" "augur config" "line 1 says which command owns the file"
has "$(sed -n '1p' "$SETTINGS")" "Host-side"    "…and that it is host-side, never read from the workspace"
if grep -qx 'share_refresh=attach' "$SETTINGS"; then ok "the key is a plain KEY=VALUE line"
else fail "the key is written as KEY=VALUE" "$(cat "$SETTINGS")"; fi

section "precedence — each pair as its OWN arm (flag > file > env > default)"

# 1. FILE beats DEFAULT (mode) — the file layer existing at all.
wipe; cfg config --share-refresh off >/dev/null 2>&1
cfg config --show; _s="$(cout)"
eq "off"             "$(val_of   share_refresh "$_s")" "file beats default: the mode is the file's"
eq "settings file"   "$(label_of share_refresh "$_s")" "…and \`--show\` says the settings file won"

# 2. FLAG beats FILE (mode) — the pair Trap 1 exists for. Before the provenance variable,
# `--share-refresh continuous` was indistinguishable from no flag at all, so the FILE would have won
# and the flag would have lost for exactly the value used to escape a persisted `off`.
cfg config --show --share-refresh continuous; _s="$(cout)"
eq "continuous"      "$(val_of   share_refresh "$_s")" "flag beats file: --share-refresh continuous wins over share_refresh=off"
eq "--share-refresh" "$(label_of share_refresh "$_s")" "…and \`--show\` says the flag won"
cfg config --show --share-refresh attach; _s="$(cout)"
eq "attach"          "$(val_of   share_refresh "$_s")" "…and for a non-default flag value too"

# 3. ENV beats DEFAULT (interval), with no file key present.
wipe
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_MACOS_REFRESH_INTERVAL=42 bash "$AUGUR" config --show ) \
    > "$TMPD/raw" 2>&1; sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"; _s="$(cout)"
eq "42"                           "$(val_of   share_refresh_interval "$_s")" "env beats default: the period is the export's"
eq "AUGUR_MACOS_REFRESH_INTERVAL" "$(label_of share_refresh_interval "$_s")" "…and \`--show\` names the export"
cfg config --show; _s="$(cout)"
eq "5"        "$(val_of   share_refresh_interval "$_s")" "…and with nothing set anywhere the built-in default is 5"
eq "default"  "$(label_of share_refresh_interval "$_s")" "…named as the default, which \${VAR:-5} could not distinguish from it"

# 4. FILE beats ENV (interval) — the genuine decision in this change. The export is global to a shell
# (a profile, every project) while the file is per project and deliberate, so specificity wins. It
# INVERTS resolve_macos_vm_cpu's env > .augur/resources.conf, whose reason is TRUST: that file is
# guest-writable and this one is not.
cfg config --share-refresh-interval 30 >/dev/null 2>&1
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_MACOS_REFRESH_INTERVAL=42 bash "$AUGUR" config --show ) \
    > "$TMPD/raw" 2>&1; sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"; _s="$(cout)"
eq "30"            "$(val_of   share_refresh_interval "$_s")" "file beats env: a stale export does not override this project's value"
eq "settings file" "$(label_of share_refresh_interval "$_s")" "…and \`--show\` says the settings file won"

# 5. FLAG beats FILE beats ENV, all three present on one command line.
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_MACOS_REFRESH_INTERVAL=42 bash "$AUGUR" config --show --share-refresh-interval 7 ) \
    > "$TMPD/raw" 2>&1; sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"; _s="$(cout)"
eq "7"                        "$(val_of   share_refresh_interval "$_s")" "flag beats file AND env"
eq "--share-refresh-interval" "$(label_of share_refresh_interval "$_s")" "…and \`--show\` says the flag won"

# 6. The two keys are INDEPENDENT. Without this, every arm above would pass on a resolver that copied
# one key's decision to the other.
wipe; cfg config --share-refresh-interval 30 >/dev/null 2>&1
cfg config --show; _s="$(cout)"
eq "30"         "$(val_of   share_refresh_interval "$_s")" "an interval-only file sets the interval…"
eq "continuous" "$(val_of   share_refresh "$_s")"          "…and leaves the mode on its default"
eq "default"    "$(label_of share_refresh "$_s")"          "…reported as the default, not as the settings file"

section "validation of each key, and the failure direction"

wipe
for _m in continuous attach off; do
    cfg config --share-refresh "$_m"; CRC=$?
    if [[ $CRC -eq 0 ]]; then ok "share_refresh=$_m is accepted"
    else fail "share_refresh=$_m is accepted" "$(cout)"; fi
done
wipe
cfg config --share-refresh sometimes; CRC=$?
if [[ $CRC -ne 0 ]]; then ok "an unknown mode is REFUSED by \`augur config\`"
else fail "an unknown mode is refused" "it would be written and then ignored on every run"; fi
has "$(cout)" "continuous, attach or off" "…naming the three modes, in the same words the flag uses"
if [[ ! -f "$SETTINGS" ]]; then ok "…and nothing is written on a refusal"
else fail "a refused mode still wrote the file" "$(cat "$SETTINGS")"; fi

# The PERIOD reuses validate_macos_refresh_interval — the flag's own validator, not a second copy — so
# `0`, a leading zero and every non-number are refused, and `0` still points at the flag that really
# stops the loop rather than being read as "off".
for _bad in 0 abc -3 5s '' 010; do
    cfg config --share-refresh-interval "$_bad"; CRC=$?
    if [[ $CRC -ne 0 ]]; then ok "share_refresh_interval='$_bad' is refused before it can be persisted"
    else fail "share_refresh_interval='$_bad' is refused" "it would reach \`sleep\` on every attach, forever"; fi
done
cfg config --share-refresh-interval 0 >/dev/null 2>&1
has "$(cout)" "does not mean" "0 is refused rather than read as 'off' (a number becoming a mode is a misreport)"
if [[ ! -f "$SETTINGS" ]]; then ok "…and no refused period is ever written"
else fail "a refused period was written" "$(cat "$SETTINGS")"; fi
cfg config --share-refresh-interval 1; CRC=$?
if [[ $CRC -eq 0 ]]; then ok "…while 1, the smallest legal period, is accepted"
else fail "1 is accepted" "$(cout)"; fi

# `--unset` of a key this augur does not know is a typo — most likely the flag's hyphenated spelling.
for _k in share-refresh nonsense ''; do
    cfg config --unset "$_k"; CRC=$?
    if [[ $CRC -ne 0 ]]; then ok "\`--unset '$_k'\` is refused (silently succeeding would be a false 'it is gone')"
    else fail "\`--unset '$_k'\` is refused" "$(cout)"; fi
done
cfg config --unset share-refresh >/dev/null 2>&1
has "$(cout)" "share_refresh_interval" "…and the refusal lists the keys that DO exist"

section "a broken file WARNS — it does not silently fall back"

# THE FAILURE DIRECTION. Someone who wrote a setting and sees no effect concludes the feature is
# broken; silence is #148 with a different cause. So a rejected value names the file, the value, the
# value used INSTEAD, and a remedy that clears it.
wipe; mkdir -p "$(project_settings_dir)"
printf 'share_refresh=sometimes\nshare_refresh_interval=nope\n' > "$SETTINGS"
cfg config --show; _s="$(cout)"
has "$_s" "share_refresh='sometimes'"                     "a bad mode is reported with the value that was rejected"
has "$_s" "project-settings"                              "…naming the file it is in"
has "$_s" "continuous"                                    "…and the value used instead"
has "$_s" "augur config --unset share_refresh"            "…and the remedy that clears it"
has "$_s" "share_refresh_interval='nope'"                 "a bad period is reported too"
has "$_s" "augur config --unset share_refresh_interval"   "…with its own remedy"
eq  "default" "$(label_of share_refresh "$_s")"           "…and the effective mode falls to the DEFAULT, reported as such"
# DROPPED, not clamped: with a good export present the fallback is the ENV layer, not the built-in 5.
# That is the difference between dropping a bad value and substituting a default for it.
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_MACOS_REFRESH_INTERVAL=42 bash "$AUGUR" config --show ) \
    > "$TMPD/raw" 2>&1; sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"; _s="$(cout)"
eq "42" "$(val_of share_refresh_interval "$_s")" "a rejected file period falls through to the ENV layer, not to the default"
has "$_s" "42s (AUGUR_MACOS_REFRESH_INTERVAL)" "…and the warning attributes the value it fell back to correctly"

# PRESENT BUT EMPTY (`share_refresh=`) is the case the _SEEN flags exist for, and it is the one that
# looks most like a bug to the operator: they wrote the key, they see the default. An ABSENT key must
# fall through silently — that is the normal state of every project — while an empty one is malformed
# input and has to be reported. Both arrive in the variable as "", so nothing but the flag can tell
# them apart, and a resolver that tested `[[ -n … ]]` instead would be silent for both. Measured
# against that mutation: it prints nothing at all and reports `continuous (default)`.
printf 'share_refresh=\nshare_refresh_interval=\n' > "$SETTINGS"
cfg config --show; _s="$(cout)"
has "$_s" "share_refresh=''"          "an EMPTY mode is reported as malformed, not treated as absent"
has "$_s" "share_refresh_interval=''" "…and so is an empty period"
eq "default" "$(label_of share_refresh "$_s")"          "…with the mode falling to the default"
eq "default" "$(label_of share_refresh_interval "$_s")" "…and the period with it"
# CONTROL: the same two keys ABSENT must say nothing at all. Without this the arms above pass on a
# resolver that warns unconditionally, which would put a complaint on every command in every project.
wipe; mkdir -p "$(project_settings_dir)"; printf '# nothing here\n' > "$SETTINGS"
cfg config --show; _s="$(cout)"
if ! printf '%s' "$_s" | grep -q "is not continuous"; then ok "control: an ABSENT key is silent (only a written-but-broken one warns)"
else fail "an absent key warned" "$_s — every project with no settings would be nagged"; fi

# Unknown keys: warn, ignore, and SURVIVE a rewrite. Forward compatibility in both directions — an
# older augur must not die on a newer one's key, and "ignored" must not quietly mean "deleted by your
# next `augur config`".
printf 'share_refresh=attach\nfuture_key=1\nnot a setting\n' > "$SETTINGS"
cfg config --show; _s="$(cout)"
has "$_s" "future_key"    "an unknown key is reported rather than swallowed"
has "$_s" "not a setting" "…and so is a line that is not KEY=VALUE at all"
eq "attach" "$(val_of share_refresh "$_s")" "…while the keys it DOES know still take effect"
cfg config --share-refresh off >/dev/null 2>&1
if grep -qx 'future_key=1' "$SETTINGS"; then ok "an unknown key SURVIVES a rewrite (an older augur must not eat a newer key)"
else fail "an unknown key survives a rewrite" "$(cat "$SETTINGS") — 'ignored' would mean 'deleted'"; fi
if grep -qx 'share_refresh=off' "$SETTINGS"; then ok "…and the rewrite still applied the new value"
else fail "the rewrite applied the new value" "$(cat "$SETTINGS")"; fi

# …AND SURVIVES IT BYTE FOR BYTE. `future_key=1` cannot detect the failure this closes: the parser
# comment-strips a line BEFORE splitting KEY=VALUE (right for the two keys it PARSES, so
# `share_refresh=attach  # 40k files` works), and re-emitting the stripped form silently TRUNCATED
# every unknown value at its first `#`. Measured on the first cut of this change:
#     future_color=#ff0000        →  future_color=
#     future_url=http://x/y#frag  →  future_url=http://x/y
# with no warning that anything was rewritten — strictly worse than the deletion the mechanism exists
# to prevent, because a newer augur then reads back a plausible value it never wrote and cannot tell
# it from operator error. Values with a `#` are not exotic: colours, URL fragments and glob patterns.
printf 'share_refresh=off\nfuture_color=#ff0000\nfuture_url=http://x/y#frag\nfuture_pattern=a#b\n' > "$SETTINGS"
cfg config --share-refresh-interval 30 >/dev/null 2>&1
_lost=""
for _kv in 'future_color=#ff0000' 'future_url=http://x/y#frag' 'future_pattern=a#b'; do
    grep -qxF "$_kv" "$SETTINGS" || _lost="${_lost}[${_kv}] "
done
if [[ -z "$_lost" ]]; then ok "an unknown key's VALUE survives a rewrite byte for byte, \`#\` included"
else fail "an unknown key's value was truncated on rewrite" "lost: ${_lost}— file now: $(tr '\n' '|' < "$SETTINGS")"; fi
# CONTROL: the inline comment the stripping exists for still works on a key this augur DOES parse.
# Without it, "preserve the raw line" could be implemented by never stripping at all, which would
# break the documented `share_refresh=attach  # this repo is 40k files` and report the file's own two
# header lines as junk on every macOS command in every configured project.
printf 'share_refresh=attach  # this repo is 40k files\n' > "$SETTINGS"
cfg config --show; _s="$(cout)"
eq "attach"        "$(val_of   share_refresh "$_s")" "control: an inline \`#\` comment after a value is still stripped for a KNOWN key"
eq "settings file" "$(label_of share_refresh "$_s")" "…and the value still counts as coming from the file"
if ! printf '%s' "$_s" | grep -q "not a KEY=VALUE"; then ok "…and the file's own \`#\` header lines are not reported as junk"
else fail "a comment line was reported as junk" "$_s — every command in every configured project would print this"; fi
# Leading/trailing whitespace around the key AND the value, both documented by the trim in the parser
# and neither pinned before. A hand-edited file is the case that produces them.
printf '  share_refresh =  off  \n' > "$SETTINGS"
cfg config --show; _s="$(cout)"
eq "off"           "$(val_of   share_refresh "$_s")" "whitespace around the key and the value is trimmed"
eq "settings file" "$(label_of share_refresh "$_s")" "…and the value is still credited to the file"

# ONCE, not twice. In macOS mode a setter reaches load_project_settings from two directions — the
# dispatch tail's resolver and cmd_config's own write path — and reading this file is not silent, so
# an unguarded second read reported the same broken line twice on one command. Two warnings about one
# line reads as two problems.
#
# DRIVEN WITH `--show`, which is the command line that actually broke it. A setter alone reported once
# even before the fix; adding `--show` made `augur config` re-resolve after its write, and the reset
# it used cleared the parsed-file cache, so the count went to 2 — with the assertion scoped just
# short of the failure. The plain setter is kept below as the control.
printf 'share_refresh=off\nfuture_key=1\n' > "$SETTINGS"
cfg config --macos --share-refresh attach --show >/dev/null 2>&1
eq "1" "$(cout | grep -c 'future_key')" "a malformed line is reported ONCE for \`config <setter> --show\` (both readers, plus the post-write re-resolve)"
printf 'share_refresh=off\nfuture_key=1\n' > "$SETTINGS"
cfg config --macos --share-refresh attach >/dev/null 2>&1
eq "1" "$(cout | grep -c 'future_key')" "…and once for a plain setter (the two readers alone)"
printf 'share_refresh=off\nfuture_key=1\n' > "$SETTINGS"
cfg config --macos --show >/dev/null 2>&1
eq "1" "$(cout | grep -c 'future_key')" "…and once for a plain \`--show\`"
# CONTROL: it is reported AT ALL. Every arm above passes on a build that never warns.
if [[ "$(cout | grep -c 'future_key')" -gt 0 ]]; then ok "control: the unknown key IS reported (the three counts above are not zero)"
else fail "the unknown key was never reported" "$(cout)"; fi

section "…and a broken file never makes the project untearable-down"

# The rule the dispatch tail states for a stale AUGUR_MACOS_REFRESH_INTERVAL, and SHARPER here:
# `unset` fixes an export, while this file survives `destroy --macos` by design, so a refusal on it
# would be permanent — and would take away the very commands that stop the loop.
_VMSTUB="$TMPD/vmstub"; mkdir -p "$_VMSTUB"
printf '#!/bin/bash\nexit 0\n' > "$_VMSTUB/augur-vm"; chmod +x "$_VMSTUB/augur-vm"
printf 'share_refresh=sometimes\nshare_refresh_interval=0\ngarbage\n' > "$SETTINGS"
for _c in down destroy status list; do
    ( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_VM_BIN="$_VMSTUB/augur-vm" bash "$AUGUR" "$_c" --macos ) >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then ok "\`$_c --macos\` still runs with a broken settings file"
    else fail "\`$_c --macos\` broke on a broken settings file" "teardown and inspection are how an operator escapes a bad setting, and this file outlives destroy"; fi
done
for _c in help version; do
    ( cd "$WORKSPACE_DIR" && HOME="$HOME" bash "$AUGUR" "$_c" --macos ) >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then ok "\`$_c --macos\` survives it too"
    else fail "\`$_c --macos\` survives a broken settings file"; fi
done
( cd "$WORKSPACE_DIR" && HOME="$HOME" bash "$AUGUR" help ) >/dev/null 2>&1
if [[ $? -eq 0 ]]; then ok "container mode is untouched by it as well"
else fail "container mode is untouched by a broken macOS settings file"; fi
# An UNREADABLE file is the other half, and it is the ONE arm that pins the trailing `return 0` in
# load_project_settings. `[[ -f ]]` passes, the redirect fails, and that makes the `while` itself
# non-zero. Measured, four ways, with an unreadable file (see the comment at load_project_settings):
#     while … done < "$f"; return 0   → caller continues   rc=0     ← as shipped
#     while … done < "$f"             → caller ABORTS      rc=1     ← what this arm catches
# An earlier cut also carried `|| true` on the redirect. It was REMOVED rather than tested, because
# the two guards are individually sufficient and therefore individually untestable: with either one
# in place, deleting the other changed no behaviour, both mutations came back 148/148, and only
# deleting BOTH was caught. A guard no mutation can fail is not a guard, it is a comment.
chmod 000 "$SETTINGS" 2>/dev/null
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_VM_BIN="$_VMSTUB/augur-vm" bash "$AUGUR" down --macos ) >/dev/null 2>&1
if [[ $? -eq 0 ]]; then ok "\`down --macos\` survives an UNREADABLE settings file (load_project_settings's \`return 0\`)"
else fail "down --macos aborted on an unreadable settings file" "the loop's redirect failure propagated out of load_project_settings"; fi
chmod 644 "$SETTINGS" 2>/dev/null
# A path that is a DIRECTORY exercises a different guard, and the claim this arm used to make about it
# was simply wrong: it said "the read fails, not the open", but `[[ -f <dir> ]]` is FALSE, so
# load_project_settings returns at its `-f` guard and the loop is never entered. The arm was therefore
# green under a mutation that removed both loop guards — a test that stays green when its stated
# mechanism is deleted. What the `-f` guard really does is testable, so that is what is asserted now:
# without it the loop opens the directory and bash prints `read error: … Is a directory` on every
# macOS command in the project (measured), a diagnostic augur did not write about a file the operator
# is never pointed at. rc stays 0 either way, so rc alone cannot see this.
rm -f "$SETTINGS"; mkdir -p "$SETTINGS"          # the path is now a directory where a file is expected
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_VM_BIN="$_VMSTUB/augur-vm" bash "$AUGUR" down --macos ) > "$TMPD/raw" 2>&1
_drc=$?; sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"
if [[ $_drc -eq 0 ]]; then ok "…and survives the settings PATH being a directory"
else fail "down --macos aborted on a settings path that is a directory" "$(cout)"; fi
if ! grep -qi 'read error\|Is a directory' "$COUT"; then ok "…silently, because \`[[ -f ]]\` skips it before the loop can open it"
else fail "a non-regular settings path leaked a shell diagnostic" "$(cout) — augur did not write this, and it names a file the operator is not told about"; fi
rmdir "$SETTINGS" 2>/dev/null

# THE DISPATCH TAIL is where the file layer is applied for every command that is not `config`, and
# nothing above this point can see whether that call exists: every precedence arm goes through
# `augur config --show`, which resolves for itself. Measured — deleting
# `resolve_macos_refresh_settings` from the dispatch tail left this file fully green before these two
# arms existed, while the shipped augur ignored the settings file on `up`, `claude`, `shell`,
# `status` and `refresh` alike.
printf 'share_refresh=off\n' > "$SETTINGS"
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_VM_BIN="$_VMSTUB/augur-vm" bash "$AUGUR" status --macos ) \
    > "$TMPD/raw" 2>&1; sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"
has "$(cout)" "Share refresh: off (settings file)" "\`status --macos\` (a real process) sees the file — so the DISPATCH TAIL resolves it"
# …and it resolves BEFORE the hard refusal, which is what makes "warn and drop" survivable: with a
# bad period in the FILE, an attaching command must not be refused, because the file value was already
# dropped. Ungated or applied late, this would refuse `shell --macos` over a file `destroy` cannot reap.
#
# The discriminator is NOT the "is not a positive whole number" text — the resolver's WARNING and the
# dispatch tail's REFUSAL share that wording, deliberately, because they state the same rule. It is
# whether the command REACHED DISPATCH: the refusal exits above it, so "Base VM … not found" (this
# fixture's next failure) can only be printed by a run the settings file did not stop.
printf 'share_refresh_interval=0\n' > "$SETTINGS"
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_VM_BIN="$_VMSTUB/augur-vm" bash "$AUGUR" shell --macos ) \
    > "$TMPD/raw" 2>&1; sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"
has   "$(cout)" "Base VM"                            "an attaching command REACHES DISPATCH with a bad period in the FILE (it was dropped first)"
hasnt "$(cout)" "unset AUGUR_MACOS_REFRESH_INTERVAL"  "…and is never sent to \`unset\` an export that is not the problem"
has   "$(cout)" "share_refresh_interval='0'"          "…while the file's bad value is still reported, on the attaching path too"
# CONTROL: the same bad value in the ENV var IS still refused, above dispatch. Without this the arm
# above would pass on an augur that had lost the dispatch-tail refusal altogether.
rm -f "$SETTINGS"
( cd "$WORKSPACE_DIR" && HOME="$HOME" AUGUR_MACOS_REFRESH_INTERVAL=0 AUGUR_VM_BIN="$_VMSTUB/augur-vm" bash "$AUGUR" shell --macos ) \
    > "$TMPD/raw" 2>&1; sed $'s/\033\\[[0-9;]*m//g' "$TMPD/raw" > "$COUT"
has   "$(cout)" "unset AUGUR_MACOS_REFRESH_INTERVAL" "control: the same bad value in the ENV var is still refused, with the export's own remedy"
hasnt "$(cout)" "Base VM"                            "…and refused ABOVE dispatch, before anything is booted"
mkdir -p "$(project_settings_dir)"
printf 'share_refresh=sometimes\nshare_refresh_interval=0\ngarbage\n' > "$SETTINGS"

section "the layer has an EFFECT — it reaches the gates and the sweep, not just \`--show\`"

# Every arm above reads `--show`, and `--show` is a report: a resolver wired only into the printer
# would pass all of them while `augur up --macos` kept sweeping every 5 s. These drive the real
# predicates and the real gated sweep entry point.
_reset() {   # the layer stack a fresh augur process would start from, in this shell
    # Clear the flag layer first, then let the SHIPPED reset do the rest — it is exactly this
    # function's job (`augur config` needs it after rewriting the file), and reimplementing it here
    # would drift.
    _MACOS_REFRESH_MODE_FROM=default
    _MACOS_REFRESH_INTERVAL_FROM=default
    # …and the PARSED-FILE CACHE, explicitly, which reset_macos_refresh_resolution deliberately does
    # NOT touch. This fixture is the "new caller that genuinely needs a fresh read" its comment names:
    # the arms below rewrite $SETTINGS with `printf` and then re-resolve IN THIS SHELL, so the file on
    # disk really has changed underneath the parse. `augur config` is not in that position — it
    # mutates _PROJECT_SETTINGS_* and project_settings_write emits those variables, so its post-write
    # state and the file agree without a re-read, and re-reading only made it report a malformed line
    # twice. A first cut of this helper reset the resolution alone and every arm below read the file
    # that had been parsed several sections earlier.
    _PROJECT_SETTINGS_LOADED=false
    reset_macos_refresh_resolution
}
_SSHLOG="$TMPD/sshlog"
ssh_macos() { printf '%s\n' "$*" >> "$_SSHLOG"; printf 'ok=1'; }
macos_vm_running() { return 0; }
printf 'x\n' > "$WORKSPACE_DIR/f"
wipe; mkdir -p "$(project_settings_dir)"

printf 'share_refresh=off\n' > "$SETTINGS"
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
if ! share_refresh_enabled;      then ok "share_refresh=off in the file turns share_refresh_enabled OFF"
else fail "a file-set 'off' reaches share_refresh_enabled" "the gate that stops all four attach sweeps and the tripwire never saw the file"; fi
if ! share_refresh_loop_enabled; then ok "…and share_refresh_loop_enabled with it"
else fail "a file-set 'off' reaches share_refresh_loop_enabled"; fi
: > "$_SSHLOG"; rm -f "$(macos_share_sweep_marker "$VM")"
refresh_macos_shares "$VM" quiet >/dev/null 2>&1
if [[ ! -s "$_SSHLOG" ]]; then ok "…and refresh_macos_shares makes NO round trip under a file-set \`off\`"
else fail "the sweep ran under a file-set 'off'" "$(cat "$_SSHLOG")"; fi

printf 'share_refresh=attach\n' > "$SETTINGS"
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
if share_refresh_enabled;        then ok "share_refresh=attach keeps the attach sweep on"
else fail "a file-set 'attach' keeps the sweep on"; fi
if ! share_refresh_loop_enabled; then ok "…and stops only the loop, which is what \`attach\` means"
else fail "a file-set 'attach' stops the loop" "the loop is the unattended cost the mode exists to remove"; fi

# CONTROL for all five arms above. Without it they would every one pass on a resolver that answered
# `off` unconditionally, and the "no round trip" arm would pass on a fixture where no sweep can run.
wipe
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
if share_refresh_enabled && share_refresh_loop_enabled; then ok "control: with no settings file everything is on (continuous)"
else fail "control: no settings file must mean continuous" "the arms above would pass on a resolver that always answers 'off'"; fi
: > "$_SSHLOG"; rm -f "$(macos_share_sweep_marker "$VM")"
refresh_macos_shares "$VM" quiet >/dev/null 2>&1
if [[ -s "$_SSHLOG" ]]; then ok "control: the same call DOES make a round trip with no settings file"
else fail "control: the sweep must reach the guest under continuous" "the 'no round trip' arm above is green because this fixture cannot sweep at all"; fi

# …and the PERIOD reaches the variable `sleep` actually reads, not only the report.
mkdir -p "$(project_settings_dir)"; printf 'share_refresh_interval=30\n' > "$SETTINGS"
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
eq "30"   "$_MACOS_REFRESH_INTERVAL"      "a file-set period lands in _MACOS_REFRESH_INTERVAL, which the loop's \`sleep\` reads"
eq "file" "$_MACOS_REFRESH_INTERVAL_FROM" "…with its provenance recorded"

section "the launch warning names the LAYER, not a flag that was never typed"

# "Restore the default with --share-refresh continuous, or by omitting the flag" is FALSE for a mode
# that came out of the file: omitting the flag is what got the operator here. They would omit it, see
# the same warning, and conclude augur was ignoring them — the misreport shape #147/#151 closed.
printf 'share_refresh=attach\n' > "$SETTINGS"
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
_w="$( warn_macos_refresh_mode 2>&1 | sed $'s/\033\\[[0-9;]*m//g' )"
has   "$_w" "attach"                             "a file-set mode still warns on every attaching command"
has   "$_w" "project-settings"                    "…and names the FILE the value came from"
has   "$_w" "augur config --unset share_refresh"  "…and the remedy that actually clears it"
hasnt "$_w" "omitting the flag"                   "…and does NOT offer 'omit the flag', which would loop the operator"
has   "$_w" "#124/#135"                           "…while still naming the issues, as the flag path does"
# CONTROL: the flag path keeps the wording it had. The pair is what pins the split — deleting the
# branch turns the arms above red and leaves this one green.
_reset; _MACOS_REFRESH_MODE=attach; _MACOS_REFRESH_MODE_FROM=flag
_w="$( warn_macos_refresh_mode 2>&1 | sed $'s/\033\\[[0-9;]*m//g' )"
has   "$_w" "omitting the flag"    "control: a FLAG-set mode still says 'or by omitting the flag'"
hasnt "$_w" "augur config --unset" "…and does not send a flag user to a file they have not got"

# THE SIBLING WARNING, in cmd_refresh_macos, which had the identical defect and was left with it: "off
# for this run" describes a flag, and a mode out of the settings file was never on this command line.
# It matters MORE here than on the launch path, because `augur refresh --macos` is the escape hatch
# FROM a persisted `off` — the one command an operator reaches while already asking "what is off, and
# where did that come from". Pinned as a pair with the flag branch, the same way the launch warning is.
#
# THE REAL cmd_refresh_macos, not a copy of its warning. A copy would pass with the branch in augur
# gutted — measured: replacing the shipped `if [[ … == file ]]` with `if false` left a copy-based arm
# 204/204 green, because the copy is not the code. So the function itself is driven, with only what it
# would boot, resolve or SSH stubbed out; the sweep is stubbed to "nothing changed", so no arm here
# contacts a guest.
require_vz()             { :; }
require_safe_workspace() { :; }
macos_project_vm()       { echo "$VM"; }
macos_vm_running()       { return 0; }
macos_ssh_host()         { echo "127.0.0.1"; }
refresh_macos_shares_now() { return "$_MACOS_SWEEP_NOWORK"; }
_refresh_out() { cmd_refresh_macos 2>&1 | sed $'s/\033\\[[0-9;]*m//g'; }

printf 'share_refresh=off\n' > "$SETTINGS"
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
_w="$( _refresh_out )"
has   "$_w" "for this project"                    "a manual refresh under a FILE-set off says 'for this project'…"
has   "$_w" "project-settings"                    "…names the file the mode came from"
has   "$_w" "augur config --unset share_refresh"  "…and gives the remedy that works"
hasnt "$_w" "for this run"                        "…and does not claim a scope the operator never chose"
# CONTROL 1: the FLAG branch keeps its wording. The pair is what pins the split — gutting either
# branch turns one of these two red and leaves the other green.
_reset; _MACOS_REFRESH_MODE=off; _MACOS_REFRESH_MODE_FROM=flag
_w="$( _refresh_out )"
has   "$_w" "for this run"         "control: a FLAG-set off on the same command still says 'for this run'"
hasnt "$_w" "for this project"     "…and not 'for this project'"
hasnt "$_w" "augur config --unset" "…and does not point at a file that holds nothing"
# CONTROL 2: the command still WORKS under a persisted `off`. It is the escape hatch FROM one, and the
# ungated sweep entry is what keeps `augur config --share-refresh off` a setting rather than a one-way
# door — a refusal here would make the remedy augur itself prints unreachable.
printf 'share_refresh=off\n' > "$SETTINGS"
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
( cmd_refresh_macos ) >/dev/null 2>&1; _rrc=$?
eq "0" "$_rrc" "control: \`augur refresh --macos\` still runs under a persisted off (it is the way out of one)"

section "\`status --macos\` names the layer too"

# `status --macos` is where "why is my edit not showing up" is actually asked, and with a persisted
# mode the mode alone stops answering it: `attach` appears for a command line that says nothing of the
# kind, with no route from there to the file.
require_vz()       { :; }
macos_vm_exists()  { return 1; }
macos_vm_running() { return 1; }
egress_enabled()   { return 1; }
macos_project_vm() { echo "$VM"; }
printf 'share_refresh=off\n' > "$SETTINGS"
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
_st="$( cmd_status_macos 2>&1 | sed $'s/\033\\[[0-9;]*m//g' )"
has "$_st" "Share refresh: off (settings file)" "status names the mode AND the layer that set it"
has "$_st" "this run:"                          "…and is still labelled as this run's setting"
wipe
_reset; resolve_macos_refresh_settings >/dev/null 2>&1
_st="$( cmd_status_macos 2>&1 | sed $'s/\033\\[[0-9;]*m//g' )"
has "$_st" "continuous (default)" "control: with no file, status says the default set it"

section "\`augur config\` needs no --macos and no VM backend"

# It writes a host-side text file and boots nothing, so `require_vz` would refuse it on a host that
# simply has no VM backend — for a file that host can perfectly well hold. The precedent is
# `init-conf`: one implementation, both dispatch blocks, scaffolding macOS-only keys. `refresh`'s
# named refusal exists because it has NO container implementation at all, which is not true of
# writing a file.
wipe
cfg config --show; CRC=$?                        # AUGUR_VM_BIN points at nothing (fixture)
eq "0" "$CRC" "\`augur config --show\` works with no --macos and no VM backend"
has "$(cout)" "share_refresh" "…and reports both keys"
# `--show` PRINTS THE PRECEDENCE ORDER. With four layers the provenance label answers "which layer
# won" but not "which layer COULD have won", and the second question is the one an operator asks when
# the answer is not the one they wanted. It is the only place that order is written down for them.
has "$(cout)" "Precedence" "…and prints the precedence order, not only the winning layer"
has "$(cout)" "AUGUR_MACOS_REFRESH_INTERVAL" "…naming the env layer, which nothing else on this page mentions"
# The path is shown $HOME-abbreviated. The literal path is long enough that the un-abbreviated form
# wraps in every warning that has to name it, and every warning about this file does.
cfg config --share-refresh off >/dev/null 2>&1
cfg config --show; _s="$(cout)"
has   "$_s" "~/.augur/project-settings/" "the settings path is shown \$HOME-abbreviated…"
hasnt "$_s" "$HOME/.augur/project-settings/" "…not as the full literal path (it wraps in every warning that names it)"
wipe
cfg config --macos --show; CRC=$?
eq "0" "$CRC" "…and with --macos as well (require_vz is never reached)"
has "$(cout)" "macOS VM mode" "…and \`--show\` says the keys are macOS-only, so container mode is not misled"
# ONE implementation, dispatched in BOTH blocks — structurally, because a `config` missing from one
# block is "Unknown command" in that mode and no dynamic arm above would notice.
_dm="$(awk 'index($0,"up)             cmd_up_macos ;;")>0 {print NR; exit}' "$AUGUR")"
_dc="$(awk 'index($0,"up)             cmd_up ;;")>0 {print NR; exit}' "$AUGUR")"
_n="$(awk 'index($0,"config)         cmd_config")>0 && $0 !~ /^ *#/ {c++} END{print c+0}' "$AUGUR")"
if [[ -n "$_dm" && -n "$_dc" && "$_dc" -gt "$_dm" ]]; then ok "both dispatch blocks are locatable (macOS ${_dm}, container ${_dc})"
else fail "both dispatch blocks are locatable" "macos=$_dm container=$_dc"; fi
if [[ "$_n" == "2" ]]; then ok "\`config\` is dispatched in BOTH blocks from one implementation (like init-conf)"
else fail "\`config\` is dispatched in both blocks" "found $_n — one mode would answer 'Unknown command: config'"; fi
# …and it is NOT in the containment gate. That gate is about handing THIS DIRECTORY to a guest; this
# command mounts nothing, and adding it would refuse `augur config --show` inside a checkout under
# ~/.augur — taking away an INSPECTION command, the direction that gate rules out for itself.
_gate="$(awk 'index($0,"require_safe_workspace ;;")>0 {print; exit}' "$AUGUR")"
if [[ -n "$_gate" ]]; then ok "the containment gate's command list is locatable"
else fail "the containment gate's command list is locatable" "the arm below would be vacuous"; fi
hasnt "$_gate" "config" "\`config\` is not in the require_safe_workspace gate (it hands nothing to a guest)"
_cbody="$(awk '/^cmd_config\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
if [[ -n "$_cbody" ]]; then ok "cmd_config's body is locatable"
else fail "cmd_config's body is locatable"; fi
hasnt "$_cbody" "require_vz"             "…and cmd_config calls no require_vz"
hasnt "$_cbody" "require_safe_workspace" "…and no require_safe_workspace of its own either"

section "both flag ORDERS are equivalent (the two parse routes)"

# `--share-refresh` is a GLOBAL flag, so the dispatch-tail loop eats it when it comes first and
# cmd_config's own loop parses it when a non-flag word (`--show`) stopped that loop. Both routes must
# end in the same write AND the same reported provenance; a first cut reported `(--share-refresh)` for
# one order and `(settings file)` for the other, for the same command.
wipe; cfg config --share-refresh off --show; _a="$(cout)"
wipe; cfg config --show --share-refresh off; _b="$(cout)"
eq "$(val_of   share_refresh "$_a")" "$(val_of   share_refresh "$_b")" "both orders resolve to the same mode"
eq "$(label_of share_refresh "$_a")" "$(label_of share_refresh "$_b")" "…and report the same winning layer"
eq "--share-refresh" "$(label_of share_refresh "$_b")" "…which is the flag, in both"
if grep -qx 'share_refresh=off' "$SETTINGS"; then ok "…and both orders actually wrote the file"
else fail "the trailing-flag order wrote the file" "$(cat "$SETTINGS" 2>/dev/null)"; fi
# ROUTE 2 HAS ITS OWN VALIDATORS, and they are not the global loop's. Every validation arm in the
# section above drives route 1 (`config --share-refresh-interval 0`, eaten by the global flag loop),
# which keeps its own validator — so deleting cmd_config's call left the suite green while
# `augur config --show --share-refresh-interval 0` exited 0 and wrote `share_refresh_interval=0` to
# disk, i.e. a period that makes `sleep 0` spin one host core for the life of the VM, persisted.
wipe
cfg config --show --share-refresh-interval 0; CRC=$?
if [[ $CRC -ne 0 ]]; then ok "route 2 validates the period too (\`config --show --share-refresh-interval 0\`)"
else fail "route 2 validated the period" "0 would be written and reach \`sleep\` on every attach, forever"; fi
if [[ ! -f "$SETTINGS" ]]; then ok "…and writes nothing on that refusal"
else fail "a route-2 refusal still wrote the file" "$(cat "$SETTINGS")"; fi
cfg config --show --share-refresh sometimes; CRC=$?
if [[ $CRC -ne 0 ]]; then ok "…and the mode, on the same route"
else fail "route 2 validated the mode" "$(cout)"; fi
# CONTROL: a GOOD value on route 2 is accepted and written, so the two arms above are not passing on a
# route that refuses everything.
cfg config --show --share-refresh-interval 30; CRC=$?
eq "0" "$CRC" "control: a valid period on route 2 is accepted"
if grep -qx 'share_refresh_interval=30' "$SETTINGS"; then ok "…and written"
else fail "a valid route-2 period was written" "$(cat "$SETTINGS" 2>/dev/null)"; fi

# A setter and an `--unset` for the same key is a contradiction, not a precedence question. BOTH keys,
# because these are two symmetric guards and only the mode's was pinned — the interval's could be
# deleted with the suite green.
wipe
cfg config --share-refresh attach --unset share_refresh; CRC=$?
if [[ $CRC -ne 0 ]]; then ok "a setter and \`--unset\` for the SAME key is refused (mode)"
else fail "a setter and --unset for the same key is refused" "whichever won, the operator would be told something they did not ask for"; fi
has "$(cout)" "contradict" "…and the refusal says why"
cfg config --share-refresh-interval 30 --unset share_refresh_interval; CRC=$?
if [[ $CRC -ne 0 ]]; then ok "…and the same for the PERIOD (the symmetric guard, previously unpinned)"
else fail "a setter and --unset for the same key is refused (interval)" "$(cout)"; fi
has "$(cout)" "contradict" "…with its own reason"
if [[ ! -f "$SETTINGS" ]]; then ok "…and neither contradiction wrote anything"
else fail "a contradiction still wrote the file" "$(cat "$SETTINGS")"; fi
# CONTROL: a setter with the OTHER key's --unset is not a contradiction and must succeed.
cfg config --share-refresh attach --unset share_refresh_interval; CRC=$?
eq "0" "$CRC" "control: a setter plus \`--unset\` of the OTHER key is not a contradiction"

# THE PERSISTENCE WARNING. A setting written once and never mentioned again is the #148 shape with a
# longer fuse: `off` persisted, and every later attach quietly skipping the mitigation. Gated on the
# MODE having been named by THIS command line, and on it not being the default.
wipe
cfg config --share-refresh off >/dev/null 2>&1; _s="$(cout)"
has "$_s" "From now on"                      "persisting a non-default mode warns that it applies to every future run"
has "$_s" "off"                              "…naming the mode"
has "$_s" "augur config --unset share_refresh" "…and the way back"
# Two controls, one per half of the gate. Without them the arm passes on a build that warns always.
cfg config --share-refresh continuous >/dev/null 2>&1
if ! printf '%s' "$(cout)" | grep -q "From now on"; then ok "control: persisting the DEFAULT mode does not warn (there is nothing to warn about)"
else fail "persisting continuous warned" "$(cout)"; fi
cfg config --share-refresh-interval 30 >/dev/null 2>&1
if ! printf '%s' "$(cout)" | grep -q "From now on"; then ok "control: setting only the PERIOD does not claim anything about the mode"
else fail "an interval-only write warned about the mode" "$(cout) — it would describe a mode this command did not touch"; fi

section "\`--unset\`, and the file's own lifecycle"

wipe
cfg config --share-refresh off --share-refresh-interval 30 >/dev/null 2>&1
if grep -qx 'share_refresh=off' "$SETTINGS" && grep -qx 'share_refresh_interval=30' "$SETTINGS"; then
    ok "one command line can set both keys, in one file"
else fail "both keys are set by one command" "$(cat "$SETTINGS" 2>/dev/null)"; fi
cfg config --unset share_refresh >/dev/null 2>&1
if ! grep -q '^share_refresh=' "$SETTINGS"; then ok "\`--unset share_refresh\` removes that key…"
else fail "--unset removes the key" "$(cat "$SETTINGS")"; fi
if grep -qx 'share_refresh_interval=30' "$SETTINGS"; then ok "…and leaves the OTHER key alone"
else fail "--unset leaves the other key alone" "$(cat "$SETTINGS")"; fi
cfg config --unset share_refresh; CRC=$?
if [[ $CRC -eq 0 ]]; then ok "…and unsetting a key that is not set is a no-op, not an error (idempotent)"
else fail "--unset of an absent key is a no-op" "$(cout)"; fi
cfg config --unset share_refresh_interval >/dev/null 2>&1
if [[ ! -f "$SETTINGS" ]]; then ok "unsetting the LAST key removes the file (a header with no settings is a state augur cannot report)"
else fail "the file is removed when the last key goes" "$(cat "$SETTINGS")"; fi
# …but "last key" means the last key ANYONE knows about, not the last one THIS augur knows. Unsetting
# the last KNOWN key while a newer augur's key is still in the file must keep the file, or forward
# compatibility survives a rewrite-with-a-value (pinned above) and dies on an `--unset` — the exact
# "'ignored' quietly means 'deleted by your next augur config'" outcome the mechanism exists to
# prevent, reached by the other door. Deleting the unknown-key half of that condition left the suite
# green: measured, `augur config --unset share_refresh` then removed the whole file.
cfg config --show; CRC=$?
has "$(cout)" "none" "…and \`--show\` then reports no settings file"
eq "0" "$CRC" "…still exiting 0 (a project with no settings is not an error)"
# …but "last key" means the last key ANYONE knows about, not the last one THIS augur knows.
wipe; mkdir -p "$(project_settings_dir)"
printf 'share_refresh=off\nfuture_key=1\n' > "$SETTINGS"
cfg config --unset share_refresh >/dev/null 2>&1
if [[ -f "$SETTINGS" ]]; then ok "unsetting the last KNOWN key keeps the file while an unknown key remains"
else fail "the file was deleted with an unknown key still in it" "a newer augur's setting is gone, silently"; fi
if grep -qx 'future_key=1' "$SETTINGS" 2>/dev/null; then ok "…with that key intact"
else fail "the unknown key survived --unset" "$(cat "$SETTINGS" 2>/dev/null)"; fi
if ! grep -q '^share_refresh=' "$SETTINGS" 2>/dev/null; then ok "…and the known key really gone"
else fail "--unset removed the known key" "$(cat "$SETTINGS")"; fi
# THE STAGED WRITE. `> "$tmp"` + `mv -f` rather than `> "$f"`: a file half-written by an interrupted
# `augur config` is what the NEXT command reads, and this layer's job is to warn about a broken file,
# not to author one. The discriminator is a read-only settings FILE in a writable directory — the
# rename replaces it, a direct redirect cannot open it. Replacing tmp+mv with `> "$f"` left the suite
# green before this arm.
wipe; cfg config --share-refresh off >/dev/null 2>&1
chmod 444 "$SETTINGS"
cfg config --share-refresh attach; CRC=$?
chmod 644 "$SETTINGS" 2>/dev/null
eq "0" "$CRC" "a write REPLACES the file by rename, so a read-only settings file in a writable dir still updates"
if grep -qx 'share_refresh=attach' "$SETTINGS" 2>/dev/null; then ok "…and the new value is what landed"
else fail "the staged write landed" "$(cat "$SETTINGS" 2>/dev/null)"; fi
if ! ls "$(project_settings_dir)"/*.new.* >/dev/null 2>&1; then ok "…leaving no staging file behind"
else fail "a staging file was left in place" "$(ls "$(project_settings_dir)")"; fi
# ALL FOUR failure sites in project_settings_write report in augur's voice. The `rm -f` branch —
# `--unset` of the last key — was the one without an error branch: it aborted under `set -e` with only
# the system's own `rm: …: Permission denied` to show for it, naming a path the operator was never
# told augur owns, on a command that had just claimed to be removing a setting. A read-only settings
# DIRECTORY is the reproducer.
wipe; cfg config --share-refresh off >/dev/null 2>&1
chmod 555 "$(project_settings_dir)"
cfg config --unset share_refresh; CRC=$?
chmod 755 "$(project_settings_dir)" 2>/dev/null
if [[ $CRC -ne 0 ]]; then ok "a failed removal of the last key is a refusal, not a silent success"
else fail "a failed removal reported success" "the operator is told the setting is gone while it is still on disk"; fi
has "$(cout)" "Cannot remove" "…in augur's own voice, naming the file (not a bare \`rm:\` from the shell)"
# CONTROL: the same command in a writable directory succeeds, so the arm above is not passing on a
# `--unset` that is broken for everyone.
wipe; cfg config --share-refresh off >/dev/null 2>&1
cfg config --unset share_refresh; CRC=$?
eq "0" "$CRC" "control: the same --unset succeeds when the directory is writable"
# …and the write group's STATUS is the write's status. A group returns its LAST command's status, so a
# group ending in a false-conditioned `if` returns 0 and MASKS a failed `echo` above it (ENOSPC,
# quota) — `|| { error "Cannot write"; }` never fires and `mv -f` installs a truncated file. Measured:
# `( { false; if [[ -z x ]]; then echo y; fi; } >/dev/null )` → rc 0. A failed `echo` cannot be
# provoked from a test without filling a filesystem, so this is asserted on the SHAPE: the last
# command inside the redirected group must be unconditional.
_wbody="$(awk '/^project_settings_write\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
if [[ -n "$_wbody" ]]; then ok "project_settings_write's body is locatable"
else fail "project_settings_write's body is locatable"; fi
_wlast="$(printf '%s\n' "$_wbody" | awk '/^ *} > "\$tmp"/{print prev} {prev=$0}')"
case "$_wlast" in
  *"if "*) fail "the write group ends in a CONDITIONAL" "[$_wlast] — a false one returns 0 and masks a failed echo above it, installing a truncated file" ;;
  *printf*) ok "the write group's last command is unconditional, so the group's status IS the write's status" ;;
  *) fail "the write group's last command is recognisable" "[$_wlast]" ;;
esac
# `--unset … --show` ON ONE COMMAND LINE, in macOS mode, where the DISPATCH TAIL has already resolved
# the OLD file before cmd_config rewrites it. Without reset_macos_refresh_resolution the cached
# resolution wins and `--show` reports `off (settings file)` for the key it has just deleted — a
# `--show` describing the state before its own write. Only reproducible with `--macos`: without it
# nothing resolved earlier, so the read is fresh by accident and the bug is invisible. Measured.
wipe; cfg config --share-refresh off >/dev/null 2>&1
cfg config --macos --unset share_refresh --show; _s="$(cout)"
eq "continuous" "$(val_of   share_refresh "$_s")" "\`--macos --unset … --show\` reports the state AFTER its own write"
eq "default"    "$(label_of share_refresh "$_s")" "…and no longer credits the settings file it just emptied"
has "$_s" "none" "…and reports the file as gone"
# CONTROL: with `--macos` and no write, the dispatch tail's resolution is what `--show` reports, and it
# must still be the file. Without this the arm above would pass on a `--show` that ignored the file.
wipe; cfg config --share-refresh off >/dev/null 2>&1
cfg config --macos --show; _s="$(cout)"
eq "settings file" "$(label_of share_refresh "$_s")" "control: \`--macos --show\` with no write still credits the file"
wipe
# A bare `augur config` is the show view: the most useful and least destructive default. Typos cannot
# hide behind it, because an unrecognised option is a hard refusal.
cfg config; has "$(cout)" "share_refresh" "a bare \`augur config\` prints the show view"
cfg config --nope; CRC=$?
if [[ $CRC -ne 0 ]]; then ok "…while an unknown option is REFUSED, not absorbed into it"
else fail "an unknown option is refused" "$(cout)"; fi
has "$(cout)" "Usage" "…with the usage it should have been"
# `--macos` AFTER the command word. cmd_config has its own `--macos) shift ;;` arm precisely because
# the global flag loop stops at the first non-flag word: `config --macos --show` is absorbed there,
# `config --show --macos` is not, and without the arm the second is a hard "unknown option" refusal
# for a command line that is otherwise unambiguous. Every other arm in this file writes `config
# --macos …`, so the arm itself was never exercised and deleting it left the suite green.
cfg config --show --macos; CRC=$?
eq "0" "$CRC" "\`config --show --macos\` is accepted (the trailing \`--macos\`, which the global loop never sees)"
has "$(cout)" "share_refresh" "…and prints the show view, not a usage refusal"

section "\`destroy --macos\` does NOT reap the settings file"

# THE REVIEW QUESTION. Everything cmd_destroy_macos removes is VM STATE — the clone, its pinned host
# key, two markers describing that clone's caches, a lock, one logfile — and several are actively
# harmful if they outlive the clone. This file is not in that class: it is operator intent about the
# PROJECT, recorded because the project's file count made the default loop too expensive, which a
# re-clone does not change. Worse, `destroy --macos && up --macos` is the remedy this feature's own
# warnings recommend, so reaping it would silently undo the operator's configuration on the exact
# command line augur told them to run.
wipe
cfg config --share-refresh attach --share-refresh-interval 30 >/dev/null 2>&1
_before="$(cat "$SETTINGS")"
_DLOG="$TMPD/dlog"; : > "$_DLOG"
vm_cli_rec() { printf '%s\n' "$*" >> "$_DLOG"; return 0; }
VM_CLI=vm_cli_rec
require_vz()           { :; }
macos_project_vm()     { echo "$VM"; }
macos_vm_exists()      { return 0; }
macos_vm_running()     { return 1; }
stop_gvproxy()         { :; }
stop_proxy()           { :; }
stop_share_refresher() { :; }
_dout="$( set -e; cmd_destroy_macos 2>&1 )"; _drc=$?
eq "0" "$_drc" "cmd_destroy_macos completes (positive control — the reaping code after the delete ran)"
if grep -qx "delete ${VM}" "$_DLOG"; then ok "…and really deleted the clone, so this is the full destroy path"
else fail "cmd_destroy_macos reached the delete" "$(cat "$_DLOG")"; fi
if [[ -f "$SETTINGS" ]]; then ok "the settings file SURVIVES \`destroy --macos\`"
else fail "destroy --macos removed the settings file" "a setting that evaporates when you recreate the VM is worthless — and 'destroy && up' is the remedy augur's own warnings recommend"; fi
eq "$_before" "$(cat "$SETTINGS" 2>/dev/null)" "…byte for byte, keys and workspace comment intact"
# The structural half, so the intent survives a rewrite of the function: the body must not name this
# file's path at all.
_dbody="$(awk '/^cmd_destroy_macos\(\)/{f=1} f{print} f&&/^}/{exit}' "$AUGUR")"
if [[ -n "$_dbody" ]]; then ok "cmd_destroy_macos's body is locatable"
else fail "cmd_destroy_macos's body is locatable" "the arms below would be vacuous"; fi
_rmlines="$(printf '%s\n' "$_dbody" | grep -E '^ *(rm|rmdir) ' || true)"
hasnt "$_rmlines" "project_settings" "…and none of its rm/rmdir lines names a settings-file path"
# CONTROL: it DOES still reap the per-VM state. Without this the arm above would pass on a destroy
# that had stopped reaping anything at all.
has "$_rmlines" "macos_share_sweep_marker" "control: it still reaps the sweep marker (VM state, unlike the settings)"
has "$_rmlines" "share_refresher_logfile"  "control: …and the refresher logfile"

finish
