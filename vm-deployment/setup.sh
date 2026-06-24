#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Claude Code VM Provisioning Script
# =============================================================================
# Run this script once on a fresh VM to set up the Claude Code environment.
#
# Usage:
#   sudo bash setup.sh
#
# What it does:
#   1. Installs system packages
#   2. Builds and installs ttyd from source
#   3. Creates a non-root "developer" user
#   4. Installs Node.js 22 via nvm (as developer)
#   5. Installs Claude Code CLI globally
#   6. Installs GitHub CLI
#   7. Installs the systemd service
#   8. Installs Tailscale, joins the tailnet, and exposes ttyd over the tailnet
#      via `tailscale serve` (tailnet-only -- not public). HTTP by default;
#      set TAILSCALE_SERVE_HTTPS=true for HTTPS (needs tailnet HTTPS certs).
# =============================================================================
#
# Tailscale prerequisites (do these in the admin console first):
#   - Enable MagicDNS on your tailnet (required -- makes the hostname resolve).
#   - (Optional) Enable HTTPS certificates on your tailnet, then set
#     TAILSCALE_SERVE_HTTPS=true in .env to serve over HTTPS instead of HTTP.
#   - (Optional) Generate a reusable auth key and set TAILSCALE_AUTH_KEY in .env
#     for non-interactive provisioning. If unset, you run `tailscale up` manually.
# See docs/infra/vm-access-tailscale.md for the full guide.

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

DEVELOPER_USER="developer"
NODE_VERSION="22"
NVM_DIR="/home/${DEVELOPER_USER}/.nvm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo " Claude Code VM Provisioning"
echo "============================================"
echo ""

# ---------- 1. System packages ----------
echo "[1/8] Installing system packages..."
apt-get update && apt-get install -y --no-install-recommends \
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
    build-essential \
    cmake \
    libjson-c-dev \
    libuv1-dev \
    libwebsockets-dev \
    && rm -rf /var/lib/apt/lists/*

# Locale
locale-gen en_US.UTF-8

# Secrets are fetched with curl + the metadata-server token + the Secret
# Manager REST API (see start.sh / the tailscale step below) -- gcloud is NOT
# used, because the google-cloud-cli snap cannot run under the ttyd unit's
# NoNewPrivileges hardening. So nothing to install here for secret access.

# ---------- 2. Build and install ttyd ----------
echo "[2/8] Building ttyd from source..."
if command -v ttyd &>/dev/null; then
    echo "  ttyd already installed, skipping build."
else
    TMPD="$(mktemp -d)"
    git clone https://github.com/tsl0922/ttyd.git "${TMPD}/ttyd"
    cd "${TMPD}/ttyd"
    mkdir build && cd build
    cmake ..
    make -j"$(nproc)"
    make install
    rm -rf "${TMPD}"
    cd "${SCRIPT_DIR}"
    echo "  ttyd installed successfully."
fi

# ---------- 3. Create non-root user ----------
echo "[3/8] Creating user '${DEVELOPER_USER}'..."
if id "${DEVELOPER_USER}" &>/dev/null; then
    echo "  User '${DEVELOPER_USER}' already exists, skipping."
else
    useradd -m -s /bin/bash "${DEVELOPER_USER}"
    echo "  User '${DEVELOPER_USER}' created."
fi

# Create workspace directory
mkdir -p "/home/${DEVELOPER_USER}/workspace"
chown "${DEVELOPER_USER}:${DEVELOPER_USER}" "/home/${DEVELOPER_USER}/workspace"

# ---------- 4. Install Node.js via nvm ----------
echo "[4/8] Installing Node.js ${NODE_VERSION} via nvm..."
su - "${DEVELOPER_USER}" -c "
    set -e
    if [ ! -d '${NVM_DIR}' ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    fi
    . '${NVM_DIR}/nvm.sh'
    nvm install '${NODE_VERSION}'
    nvm use '${NODE_VERSION}'
    nvm alias default '${NODE_VERSION}'
"

# Create a stable symlink to the resolved node version
NODE_REAL_PATH=$(su - "${DEVELOPER_USER}" -c ". '${NVM_DIR}/nvm.sh' && nvm which ${NODE_VERSION}" | head -1 | xargs dirname | xargs dirname)
if [ -d "${NODE_REAL_PATH}" ]; then
    su - "${DEVELOPER_USER}" -c "ln -sf '${NODE_REAL_PATH}' '${NVM_DIR}/versions/node/current'"
fi

# Add developer's node to PATH globally
PROFILE_LINE='export PATH="/home/developer/.nvm/versions/node/current/bin:$PATH"'
if ! grep -qxF "$PROFILE_LINE" "/home/${DEVELOPER_USER}/.profile" 2>/dev/null; then
    echo "$PROFILE_LINE" >> "/home/${DEVELOPER_USER}/.profile"
    chown "${DEVELOPER_USER}:${DEVELOPER_USER}" "/home/${DEVELOPER_USER}/.profile"
fi

# ---------- 5. Install Claude Code CLI ----------
echo "[5/8] Installing Claude Code CLI..."
su - "${DEVELOPER_USER}" -c "
    set -e
    . '${NVM_DIR}/nvm.sh'
    npm install -g @anthropic-ai/claude-code
"
echo "  Claude Code CLI installed."

# Provision Claude Code settings (provider/model config; no secrets live here
# -- the auth token is injected at runtime via start.sh from Secret Manager).
CLAUDE_CFG_DIR="/home/${DEVELOPER_USER}/.claude"
install -d -m 700 -o "${DEVELOPER_USER}" -g "${DEVELOPER_USER}" "${CLAUDE_CFG_DIR}"
if [ -f "${SCRIPT_DIR}/claude-settings.json" ]; then
    install -m 600 "${SCRIPT_DIR}/claude-settings.json" "${CLAUDE_CFG_DIR}/settings.json"
    chown "${DEVELOPER_USER}:${DEVELOPER_USER}" "${CLAUDE_CFG_DIR}/settings.json"
    echo "  Claude Code settings provisioned to ${CLAUDE_CFG_DIR}/settings.json"
fi

# ---------- 6. Install GitHub CLI ----------
echo "[6/8] Installing GitHub CLI..."
if command -v gh &>/dev/null; then
    echo "  gh already installed, skipping."
else
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
        && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && apt-get update \
        && apt-get install -y --no-install-recommends gh \
        && rm -rf /var/lib/apt/lists/*
    echo "  GitHub CLI installed."
fi

# ---------- 7. Install systemd service ----------
echo "[7/8] Installing systemd service..."
cp "${SCRIPT_DIR}/claude-code-ttyd.service" /etc/systemd/system/claude-code-ttyd.service
cp "${SCRIPT_DIR}/start.sh" "/home/${DEVELOPER_USER}/start.sh"
chown "${DEVELOPER_USER}:${DEVELOPER_USER}" "/home/${DEVELOPER_USER}/start.sh"
chmod +x "/home/${DEVELOPER_USER}/start.sh"

# Stage the env file at the service location. Prefer the real .env from the
# checkout (so values like ANTHROPIC_API_KEY / TAILSCALE_AUTH_KEY flow through
# in one shot); fall back to .env.example.
if [ ! -f "/home/${DEVELOPER_USER}/.env" ]; then
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        cp "${SCRIPT_DIR}/.env" "/home/${DEVELOPER_USER}/.env"
        chown "${DEVELOPER_USER}:${DEVELOPER_USER}" "/home/${DEVELOPER_USER}/.env"
        chmod 600 "/home/${DEVELOPER_USER}/.env"
        echo "  Staged ${SCRIPT_DIR}/.env -> /home/${DEVELOPER_USER}/.env (chmod 600)"
    elif [ -f "${SCRIPT_DIR}/.env.example" ]; then
        cp "${SCRIPT_DIR}/.env.example" "/home/${DEVELOPER_USER}/.env"
        chown "${DEVELOPER_USER}:${DEVELOPER_USER}" "/home/${DEVELOPER_USER}/.env"
        chmod 600 "/home/${DEVELOPER_USER}/.env"
        echo ""
        echo "  NOTE: A default .env was created at /home/${DEVELOPER_USER}/.env."
        echo "  Please edit it and set your ANTHROPIC_API_KEY before starting."
        echo ""
    fi
fi

systemctl daemon-reload

# ---------- 8. Install Tailscale and expose ttyd over the tailnet ----------
echo "[8/8] Setting up Tailscale..."
if command -v tailscale &>/dev/null; then
    echo "  tailscale already installed, skipping install."
else
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "  tailscale installed."
fi
systemctl enable --now tailscaled

# Read Tailscale config from the deployed .env (created in step 7).
TS_ENV_FILE="/home/${DEVELOPER_USER}/.env"
TS_AUTH_KEY=""
TS_HOSTNAME="claude-code"
TS_PROJECT=""
TS_AUTH_KEY_SECRET=""
TS_SERVE_HTTPS="false"
if [ -f "${TS_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    TS_AUTH_KEY="$(set -a; source "${TS_ENV_FILE}"; echo "${TAILSCALE_AUTH_KEY:-}")"
    TS_HOSTNAME="$(set -a; source "${TS_ENV_FILE}"; echo "${TAILSCALE_HOSTNAME:-claude-code}")"
    TS_PROJECT="$(set -a; source "${TS_ENV_FILE}"; echo "${GCP_PROJECT:-}")"
    TS_AUTH_KEY_SECRET="$(set -a; source "${TS_ENV_FILE}"; echo "${TAILSCALE_AUTH_KEY_SECRET:-}")"
    TS_SERVE_HTTPS="$(set -a; source "${TS_ENV_FILE}"; echo "${TAILSCALE_SERVE_HTTPS:-false}")"
fi

# Resolve the Tailscale auth key from Secret Manager if a secret name is set.
# (One-time bootstrap secret; only needed when joining the tailnet.) Uses curl
# + the metadata token + REST API -- see start.sh for the same pattern.
if [ -z "${TS_AUTH_KEY}" ] && [ -n "${TS_AUTH_KEY_SECRET}" ] && [ -n "${TS_PROJECT}" ]; then
    TS_TOKEN="$(curl -fsS -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
        2>/dev/null | jq -r '.access_token // empty')" || TS_TOKEN=""
    if [ -n "${TS_TOKEN}" ]; then
        TS_AUTH_KEY="$(curl -fsS -H "Authorization: Bearer ${TS_TOKEN}" \
            "https://secretmanager.googleapis.com/v1/projects/${TS_PROJECT}/secrets/${TS_AUTH_KEY_SECRET}/versions/latest:access" \
            2>/dev/null | jq -r '.payload.data // empty' | base64 -d 2>/dev/null)" || TS_AUTH_KEY=""
        [ -n "${TS_AUTH_KEY}" ] && echo "  Fetched TAILSCALE_AUTH_KEY from Secret Manager."
    fi
fi

# Default ttyd port (must match start.sh) for the serve proxy target.
TS_TTYD_PORT="$(set -a; source "${TS_ENV_FILE}"; echo "${TTYD_PORT:-7681}")"

# Scheme: HTTP by default (still encrypted end-to-end by the WireGuard tunnel).
# Set TAILSCALE_SERVE_HTTPS=true to serve HTTPS instead (requires "HTTPS
# Certificates" enabled on the tailnet in the Tailscale admin console).
if [ "${TS_SERVE_HTTPS}" = "true" ]; then
    TS_SERVE_FLAG="--https=443"
    TS_SCHEME="https"
else
    TS_SERVE_FLAG="--http=80"
    TS_SCHEME="http"
fi

if [ -n "${TS_AUTH_KEY}" ]; then
    echo "  Joining tailnet (non-interactive) as '${TS_HOSTNAME}'..."
    tailscale up --auth-key="${TS_AUTH_KEY}" --hostname="${TS_HOSTNAME}"
    echo "  Configuring tailscale serve ${TS_SERVE_FLAG} -> http://localhost:${TS_TTYD_PORT}..."
    tailscale serve --bg ${TS_SERVE_FLAG} "http://localhost:${TS_TTYD_PORT}"
    TS_STATUS="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "unknown" | rtrimstr(".")')"
    echo "  Tailscale ready. Web terminal: ${TS_SCHEME}://${TS_STATUS}"
else
    echo ""
    echo "  NOTE: TAILSCALE_AUTH_KEY is not set. Complete Tailscale setup manually:"
    echo "    sudo tailscale up --hostname=${TS_HOSTNAME}"
    echo "    sudo tailscale serve --bg ${TS_SERVE_FLAG} http://localhost:${TS_TTYD_PORT}"
    echo "  (The 'tailscale up' command prints a URL to authorize this VM.)"
    echo ""
fi

echo ""
echo "============================================"
echo " Provisioning complete!"
echo "============================================"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Edit the environment file:"
echo "       sudo nano ${SCRIPT_DIR}/.env"
echo ""
echo "  2. Start the ttyd service:"
echo "       sudo systemctl enable --now claude-code-ttyd"
echo ""
echo "  3. Open the web terminal (from a device on your tailnet):"
echo "       https://<hostname>.<tailnet>.ts.net"
echo "       (or run 'sudo tailscale serve ...' if TAILSCALE_AUTH_KEY was unset)"
echo ""
echo "  4. Add other users/devices: invite them to the tailnet and apply ACLs."
echo "       See docs/infra/vm-access-tailscale.md"
echo ""
echo "  Useful commands:"
echo "       sudo systemctl status claude-code-ttyd"
echo "       sudo journalctl -u claude-code-ttyd -f"
echo "       sudo tailscale status"
echo "       sudo tailscale serve status"
echo "       sudo systemctl restart claude-code-ttyd"
echo ""
