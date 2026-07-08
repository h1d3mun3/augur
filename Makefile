# augur — build/test orchestration shared by CI (.github/workflows/ci.yml) and humans, so the
# exact commands CI runs are runnable locally (and vice-versa). `unit` and `offline-tests` map
# 1:1 to the two free GitHub-hosted jobs; `container-e2e` and `e2e` are LOCAL-only pre-release
# gates (they need Apple Container / a macOS VM, which NO GitHub-hosted runner can do — their
# arm64 macOS runners are themselves Virtualization.framework guests with no nested virt. See
# README "Continuous integration").
#
#   make unit           build-unit job (macos-26): Swift build/test, shellcheck, version smoke.
#                        No engine/VM needed.
#   make offline-tests  offline-tests job (ubuntu-latest): seam + command-construction shell
#                        tiers via a `container` shim. No engine/VM needed.
#   make container-e2e  LOCAL egress FAIL-CLOSED proof on Apple Container (stage -> build image
#                        -> live egress assertions). The security layer; needs macOS 26+.
#   make e2e            LOCAL macOS pre-release gate: boot the VM, xcodebuild test, virtiofs +
#                        testmanagerd + VM-mode egress fail-closed. Never a CI job.

SHELL := /usr/bin/env bash
UNAME := $(shell uname)

.PHONY: help unit swift-build swift-test shellcheck offline-tests version-smoke \
        container-e2e stage image egress e2e

help:
	@echo "augur make targets:"
	@echo "  make unit           Swift build/test + shellcheck + version smoke (CI: macos-26)"
	@echo "  make offline-tests  seam + command-construction shell tiers (CI: ubuntu-latest)"
	@echo "  make container-e2e  LOCAL egress fail-closed E2E on Apple Container (needs macOS 26+)"
	@echo "  make e2e            LOCAL macOS VM pre-release gate (boots a VM — never in CI)"
	@echo "  components: swift-build  swift-test  shellcheck  offline-tests  version-smoke"

# ── build-unit (macos-26) ─────────────────────────────────────────────────────
unit: swift-build swift-test shellcheck version-smoke
	@echo "== unit: all checks passed =="

# augur-vm imports Virtualization.framework (macOS only) — build it only on Darwin. augur-proxy
# is cross-platform (POSIX sockets, no deps), so it builds everywhere.
swift-build:
	@if [ "$(UNAME)" = "Darwin" ]; then \
	  echo "== swift build: augur-vm =="; (cd augur-vm && swift build); \
	else echo "== swift build: skipping augur-vm (macOS/Virtualization only) =="; fi
	@echo "== swift build: augur-proxy =="
	cd augur-proxy && swift build

# Only augur-proxy ships unit tests (AugurProxyCoreTests). augur-vm has no test target, so it is
# build-only (its real exercise is the macOS-VM e2e gate).
swift-test:
	@echo "== swift test: augur-proxy =="
	cd augur-proxy && swift test

# Lint the shell surface in two passes:
#   A) error-severity across ALL shell — catches genuine bugs without a flag-day cleanup of the
#      large, pre-existing augur/install scripts (raise to --severity=warning once they're clean).
#   B) the NEW test harness held to warning-severity. SC1090/SC1091 (can't follow dynamic `source`)
#      are excluded — the harness sources lib.sh / augur by a runtime path on purpose.
shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "installing shellcheck (no sudo)..."; \
	  (command -v brew >/dev/null 2>&1 && brew install shellcheck) || \
	  { echo "shellcheck not found. Install it without sudo: 'brew install shellcheck', or drop a"; \
	    echo "release binary from https://github.com/koalaman/shellcheck/releases onto PATH, then re-run."; \
	    exit 1; }; }
	@echo "== shellcheck (errors fail, across all shell) =="
	shellcheck --severity=error augur install tests/*.sh tests/shims/*
	@echo "== shellcheck (strict on the new test harness) =="
	SHELLCHECK_OPTS='-e SC1090 -e SC1091' shellcheck --severity=warning tests/22_egress_failclosed.sh tests/e2e_macos_vm.sh

# Offline shell tiers (00/01/11 + macOS source-guard tiers): seam + command-construction contracts
# via a `container` shim. Live tiers (21/22/30) self-skip without their prereqs, so this is safe
# with no engine/VM present. Runs on the free Linux (ubuntu) CI job.
offline-tests:
	@echo "== offline shell tiers =="
	bash tests/run.sh

# `augur version` is side-effect-free (no engine) — a cheap smoke that the script parses and runs.
version-smoke:
	@echo "== version smoke =="
	bash ./augur version

# ── container-e2e (LOCAL — Apple Container, macOS 26+) ────────────────────────
container-e2e: egress
	@echo "== container-e2e: egress fail-closed proof passed =="

# Stage ~/.augur (host augur-proxy + managed allowlist).
stage:
	@echo "== stage: bash install =="
	bash install

# Build the agent image from the Dockerfile via Apple Container's BuildKit builder.
image: stage
	@echo "== image: augur build =="
	bash ./augur build

# The security gate: bring up egress mode (fires the boot self-test) and assert fail-closed.
# AUGUR_TEST_REQUIRE_EGRESS=1 turns any missing prerequisite into a FAILURE, never a skip.
egress: image
	AUGUR_TEST_LIVE=1 AUGUR_TEST_REQUIRE_EGRESS=1 AUGUR_ACCEPT_PROJECT_CONF=1 bash tests/run.sh 22

# ── e2e (LOCAL macOS VM gate — pre-release, never CI) ─────────────────────────
# Boots the macOS VM and runs the heavy E2E no GitHub-hosted runner can: xcodebuild test inside
# the VM + virtiofs mount + testmanagerd reachability + VM-mode egress fail-closed. Run it from
# your project directory before tagging a release. See README "Pre-release gate".
e2e:
	AUGUR_TEST_LIVE=1 bash tests/e2e_macos_vm.sh
