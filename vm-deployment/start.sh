#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Startup Script for Claude Code VM (ttyd web terminal)
# =============================================================================
# This script is called by the systemd service (claude-code-ttyd.service).
# It reads configuration from the .env file and starts ttyd.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# --- Load environment variables ---
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
else
    echo "ERROR: ${ENV_FILE} not found."
    echo "Copy .env.example to .env and configure it first."
    exit 1
fi

# --- Helper: resolve a value from GCP Secret Manager ---
# fetch_secret <dest_var> <secret_name>. If <secret_name> is empty, no-op
# (the existing .env value is used). Requires GCP_PROJECT + gcloud CLI. The
# VM's attached service account must have roles/secretmanager.secretAccessor.
# See docs/infra/gcp-secrets.md.
fetch_secret() {
    local dest="$1" secret_name="${2:-}"
    [ -z "${secret_name}" ] && return 0
    if [ -z "${GCP_PROJECT:-}" ]; then
        echo "ERROR: GCP_PROJECT is not set; needed to fetch secret '${secret_name}'." >&2
        exit 1
    fi
    if ! command -v gcloud >/dev/null 2>&1; then
        echo "ERROR: gcloud CLI not installed; cannot fetch secret '${secret_name}'." >&2
        exit 1
    fi
    local value
    if ! value="$(gcloud secrets versions access latest --secret="${secret_name}" --project="${GCP_PROJECT}" 2>/dev/null)"; then
        echo "ERROR: failed to fetch secret '${secret_name}' from Secret Manager." >&2
        echo "       Verify the VM service account has roles/secretmanager.secretAccessor." >&2
        exit 1
    fi
    printf -v "${dest}" '%s' "${value}"
}

echo "============================================"
echo " Claude Code Remote Development Environment"
echo "============================================"

# --- Resolve secrets from GCP Secret Manager (override .env plaintext) ---
fetch_secret ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY_SECRET:-}"
fetch_secret TTYD_CREDENTIAL   "${TTYD_CREDENTIAL_SECRET:-}"

# --- Validate required env vars ---
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ERROR: ANTHROPIC_API_KEY is not set."
    echo "Set ANTHROPIC_API_KEY (plaintext) or ANTHROPIC_API_KEY_SECRET (Secret Manager) in ${ENV_FILE}"
    exit 1
fi

# --- Export for child processes ---
export ANTHROPIC_API_KEY

# --- Configure git (if env vars provided) ---
if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "${GIT_USER_NAME}"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "${GIT_USER_EMAIL}"
fi

# --- Determine settings ---
TTYD_PORT="${TTYD_PORT:-7681}"
TTYD_CREDENTIAL="${TTYD_CREDENTIAL:-}"
# ttyd must bind to loopback only. Public exposure is handled by Tailscale
# (tailscale serve), which proxies the tailnet HTTPS endpoint to this port.
TTYD_INTERFACE="${TTYD_INTERFACE:-127.0.0.1}"

echo ""
echo "Starting ttyd on ${TTYD_INTERFACE}:${TTYD_PORT} (loopback only)..."
echo "Connect via Tailscale: http://<hostname>.<tailnet>.ts.net  (HTTP by default;"
echo "set TAILSCALE_SERVE_HTTPS=true in .env for HTTPS)."
echo "(requires 'tailscale serve' configured -- see docs/infra/vm-access-tailscale.md)"
echo ""

# --- Build ttyd command ---
TTYD_ARGS=(
    ttyd
    --interface "${TTYD_INTERFACE}"
    --port "${TTYD_PORT}"
    --writable
)

# Defense in depth: optional credential auth on top of Tailscale access control.
if [ -n "${TTYD_CREDENTIAL}" ]; then
    TTYD_ARGS+=(--credential "${TTYD_CREDENTIAL}")
    echo "ttyd credential auth enabled (in addition to the Tailscale gate)."
else
    echo "NOTE: No TTYD_CREDENTIAL set. Access is gated solely by Tailscale membership."
    echo "Set TTYD_CREDENTIAL=user:password in ${ENV_FILE} for an extra auth layer."
fi

# --- Launch ttyd with bash as the shell ---
exec "${TTYD_ARGS[@]}" bash
