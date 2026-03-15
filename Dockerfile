ARG SWIFT_VERSION=6.0
FROM swift:${SWIFT_VERSION}-jammy

# Install Node.js 22
RUN apt-get update && apt-get install -y curl ca-certificates gnupg sudo procps findutils jq wget git \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user
RUN useradd -m -u 1001 -s /bin/bash dev

# Install both CLIs globally
RUN npm install -g @anthropic-ai/claude-code
RUN npm install -g @openai/codex

# Allow dev user to use sudo without password
RUN echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

WORKDIR /workspace

USER dev

CMD ["bash"]
