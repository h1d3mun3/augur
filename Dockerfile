ARG SWIFT_VERSION=6.0
FROM swift:${SWIFT_VERSION}-jammy

# System dependencies + Node.js 22
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl ca-certificates gnupg sudo procps findutils jq wget git \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1001 -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install CLI tools
RUN npm install -g @anthropic-ai/claude-code @openai/codex

WORKDIR /workspace
USER dev
CMD ["bash"]
