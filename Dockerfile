ARG SWIFT_VERSION=latest
FROM swift:${SWIFT_VERSION}

# System dependencies + GitHub CLI
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl ca-certificates gnupg procps findutils jq wget git \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Optional extra apt packages declared in ~/.augur/provision/container-packages.conf
# (host-side, TOFU-approved before this build — see container_provision_prepare in
# `augur`). Empty by default, so a normal build is unaffected; each package name was
# already validated against a safe charset host-side before reaching this ARG, so the
# unquoted expansion below (needed to word-split multiple names into separate apt-get
# arguments) cannot smuggle shell metacharacters.
ARG EXTRA_APT_PACKAGES=""
RUN if [ -n "$EXTRA_APT_PACKAGES" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends $EXTRA_APT_PACKAGES \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# Create non-root user (no sudo — the agent runs as dev with no elevated privileges)
RUN useradd -m -u 1001 -s /bin/bash dev

# AUGUR_AGENT_SEAM | agent install (Docker image). Swap installer + pin per agent. See docs §4 C2.
# Install Claude Code via the official native installer so installMethod matches
# the host's (the shared ~/.claude.json reports "native"). The AMFI code-signing
# issue that forces native on macOS does not apply to Linux; native is used here
# only to keep the install method consistent with the shared config and silence
# the "claude command ... missing or broken · run claude install to repair" warning.
# Must run as dev: the installer targets $HOME/.local, and PATH must expose it so
# `docker exec ... claude` (a non-login shell) can find the binary.
USER dev
# Download the installer to a temp file before executing — separates the network fetch
# from execution so the script can be inspected and avoids piping untrusted content to bash.
RUN _installer=$(mktemp) \
    && curl -fsSL https://claude.ai/install.sh -o "$_installer" \
    && bash "$_installer" latest \
    && rm -f "$_installer"
ENV PATH=/home/dev/.local/bin:$PATH
# Pin the Claude binary: never auto-update it at runtime. The binary lives in the
# agent-writable ~/.local/bin, and `augur setup-token` attaches it to the operator's
# terminal — so augur verifies it against this image before that flow. Disabling the
# autoupdater keeps the on-disk binary byte-identical to the image (no false positives
# in that check) and removes the binary's ability to rewrite itself.
# AUGUR_AGENT_SEAM | agent fixed env (mirror agent_fixed_env). Pins the binary (no self-rewrite).
ENV DISABLE_AUTOUPDATER=1

# Pre-create the per-project history dir (dev-owned) and seed a minimal
# ~/.claude.json. augur bind-mounts ~/.claude/projects (this project's history
# only — every leaf under it, never the whole ~/.claude) — so the guest cannot
# read other projects' transcripts or tamper with host auth/settings. This RUN's
# mkdir is a dev-owned fallback for any path that skips that mount; normally the
# bind mount fully shadows it, source directory ownership and all. The minimal
# ~/.claude.json skips onboarding WITHOUT copying the host's real config (which
# enumerates every project on the host). Auth is injected via env
# (CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY), never mounted.
# The seed is intentionally GENERIC and PERMANENT (no workspace-trust entry, and nothing later
# adds one): augur does not pre-trust the mounted workspace. Claude Code's own folder-trust
# dialog runs once inside the guest like it would anywhere else — the guest is not special-cased
# to skip it. See docs/decisions/0012-drop-workspace-trust-seed.md (which supersedes 0011).
# AUGUR_AGENT_SEAM | agent state seed — pre-create the per-project history parent + minimal config.
RUN mkdir -p /home/dev/.claude/projects \
    && printf '{"hasCompletedOnboarding":true,"installMethod":"native"}\n' > /home/dev/.claude.json

# Optional custom CA certificate, injected by `augur install-cert <cert.crt>` via a build-arg.
# INERT by default: a normal `augur build`/`augur update` passes no value, so the `if` guard makes
# this a no-op — the rootfs is unaffected (only empty USER-switch metadata layers are added).
# `augur install-cert` re-runs this same build with AUGUR_CA_CERT_B64 set to the base64 of a
# SINGLE host-validated PEM cert (validated + TOFU-approved host-side before it ever reaches this
# ARG). It is decoded into the system trust store so every OS-store-consuming guest TLS client
# trusts it: curl, git, wget, gh (Go), and Claude Code (the native installer reads the OS store).
# NOT covered (they ship their own trust store): Node/npm (NODE_EXTRA_CA_CERTS), Python-requests
# (REQUESTS_CA_BUNDLE), rustls — set those per-tool if needed. Runs as root (the trust store is
# root-owned) then drops back to dev, so the container still runs unprivileged. Placed last so
# toggling the arg only rebuilds this trailing layer, not the heavy apt/gh/claude layers above.
# SECURITY: a trusted CA lets its key-holder MITM the guest's TLS to every allowlisted domain —
# this is why augur gates it behind an explicit command with a blast-radius warning.
# AUGUR_AGENT_SEAM | agent trust store — native Claude Code reads the OS store, so no per-agent env needed.
ARG AUGUR_CA_CERT_B64=""
USER root
RUN if [ -n "$AUGUR_CA_CERT_B64" ]; then \
      printf '%s' "$AUGUR_CA_CERT_B64" | base64 -d > /usr/local/share/ca-certificates/augur-custom-ca.crt \
      && update-ca-certificates; \
    fi
USER dev

# No WORKDIR: the project is bind-mounted at /workspace-<slug> and the run command
# sets the working directory via `-w` at runtime, so a baked-in WORKDIR would only
# create a stray empty directory in the image.
CMD ["bash"]
