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

# Create non-root user (no sudo — the agent runs as dev with no elevated privileges)
RUN useradd -m -u 1001 -s /bin/bash dev

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
    && bash "$_installer" stable \
    && rm -f "$_installer"
ENV PATH=/home/dev/.local/bin:$PATH
# Pin the Claude binary: never auto-update it at runtime. The binary lives in the
# agent-writable ~/.local/bin, and `augur setup-token` attaches it to the operator's
# terminal — so augur verifies it against this image before that flow. Disabling the
# autoupdater keeps the on-disk binary byte-identical to the image (no false positives
# in that check) and removes the binary's ability to rewrite itself.
ENV DISABLE_AUTOUPDATER=1

# Pre-create the per-project history dir (dev-owned) and seed a minimal
# ~/.claude.json. augur bind-mounts ONLY ~/.claude/projects/-workspace-<slug>
# (this project's history) — never the whole ~/.claude — so the guest cannot read
# other projects' transcripts or tamper with host auth/settings. Pre-creating the
# parent here keeps it dev-owned; otherwise a bind mount of the leaf dir makes
# Docker create ~/.claude as root and Claude Code (uid 1001) can't write. The
# minimal ~/.claude.json skips onboarding WITHOUT copying the host's real config
# (which enumerates every project on the host). Auth is injected via env
# (CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY), never mounted.
RUN mkdir -p /home/dev/.claude/projects \
    && printf '{"hasCompletedOnboarding":true,"installMethod":"native"}\n' > /home/dev/.claude.json

# No WORKDIR: the project is bind-mounted at /workspace-<slug> and the run command
# sets the working directory via `-w` at runtime, so a baked-in WORKDIR would only
# create a stray empty directory in the image.
CMD ["bash"]
