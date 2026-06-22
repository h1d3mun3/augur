ARG SWIFT_VERSION=latest
FROM swift:${SWIFT_VERSION}

# System dependencies + Node.js 22 + GitHub CLI
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl ca-certificates gnupg sudo procps findutils jq wget git \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1001 -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install Claude Code via the official native installer so installMethod matches
# the host's (the shared ~/.claude.json reports "native"). The AMFI code-signing
# issue that forces native on macOS does not apply to Linux; native is used here
# only to keep the install method consistent with the shared config and silence
# the "claude command ... missing or broken · run claude install to repair" warning.
# Must run as dev: the installer targets $HOME/.local, and PATH must expose it so
# `docker exec ... claude` (a non-login shell) can find the binary.
USER dev
RUN curl -fsSL https://claude.ai/install.sh | bash -s stable
ENV PATH=/home/dev/.local/bin:$PATH

# No WORKDIR: the project is bind-mounted at /workspace-<slug> and the run command
# sets the working directory via `-w` at runtime, so a baked-in WORKDIR would only
# create a stray empty directory in the image.
CMD ["bash"]
