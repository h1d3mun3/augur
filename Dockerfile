# Codex requires Node.js v22+, Claude Code works fine on v22 too
FROM node:22-slim

# Create a non-root user
RUN useradd -m -u 1001 -s /bin/bash dev

# Install system utilities
RUN apt-get update && apt-get install -y \
    bash curl wget git jq \
    ca-certificates gnupg sudo \
    procps findutils \
    && rm -rf /var/lib/apt/lists/*

# Install both CLIs globally
RUN npm install -g @anthropic-ai/claude-code
RUN npm install -g @openai/codex

# Allow dev user to use sudo without password
RUN echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

WORKDIR /workspace

USER dev

CMD ["bash"]
