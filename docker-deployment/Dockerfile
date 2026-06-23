# =============================================================================
# Claude Code Remote Development Environment
# =============================================================================
# A containerized Claude Code CLI accessible via web terminal (ttyd).
# See: docs/infra/docker-init/requirement.md
# =============================================================================

# ---------- Stage 1: Build ttyd from source ----------
FROM ubuntu:24.04 AS ttyd-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    git \
    libjson-c-dev \
    libuv1-dev \
    libwebsockets-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/tsl0922/ttyd.git /tmp/ttyd \
    && cd /tmp/ttyd \
    && mkdir build && cd build \
    && cmake .. \
    && make -j"$(nproc)" \
    && make install

# ---------- Stage 2: Runtime image ----------
FROM ubuntu:24.04

LABEL maintainer="wade"
LABEL description="Claude Code remote development environment with web terminal"

# --- Environment ---
ENV DEBIAN_FRONTEND=noninteractive
ENV TTYD_PORT=7681
ENV NVM_DIR=/home/developer/.nvm
ENV NODE_VERSION=22

# --- Install system packages ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    python3 \
    python3-pip \
    python3-venv \
    openssh-client \
    locales \
    libjson-c5 \
    libuv1t64 \
    libwebsockets19t64 \
    libwebsockets-evlib-uv \
    && rm -rf /var/lib/apt/lists/*

# --- Locale ---
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# --- Create non-root user ---
RUN useradd -m -s /bin/bash developer

# --- Install Node.js via nvm (as developer) ---
USER developer
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install "$NODE_VERSION" \
    && nvm use "$NODE_VERSION" \
    && nvm alias default "$NODE_VERSION"

# Dynamically resolve the actual Node.js path (avoid hardcoding patch version)
RUN NODE_REAL_PATH=$(ls -d /home/developer/.nvm/versions/node/v${NODE_VERSION}.* | head -1) \
    && ln -sf "${NODE_REAL_PATH}" /home/developer/.nvm/versions/node/current
ENV PATH="/home/developer/.nvm/versions/node/current/bin:${PATH}"

# --- Install Claude Code CLI ---
RUN . "$NVM_DIR/nvm.sh" \
    && npm install -g @anthropic-ai/claude-code

# --- Install GitHub CLI ---
USER root
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*
USER developer

# --- Copy ttyd binary from builder ---
USER root
COPY --from=ttyd-builder /usr/local/bin/ttyd /usr/local/bin/ttyd
RUN chmod +x /usr/local/bin/ttyd
USER developer

# --- Workspace ---
RUN mkdir -p /home/developer/workspace
WORKDIR /home/developer/workspace

# --- Entrypoint script ---
COPY --chown=developer:developer entrypoint.sh /home/developer/entrypoint.sh
USER root
RUN chmod +x /home/developer/entrypoint.sh
USER developer

# --- Ports ---
EXPOSE ${TTYD_PORT}

# --- Volumes ---
VOLUME ["/home/developer/workspace", "/home/developer/.claude"]

# --- Health check ---
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:${TTYD_PORT}/ || exit 1

# --- Start ---
ENTRYPOINT ["/home/developer/entrypoint.sh"]
