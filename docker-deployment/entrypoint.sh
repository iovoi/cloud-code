#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Entrypoint for Claude Code Remote Dev Container
# =============================================================================

echo "============================================"
echo " Claude Code Remote Development Environment"
echo "============================================"

# --- Validate required env vars ---
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ERROR: ANTHROPIC_API_KEY is not set."
    echo "Pass it via: docker run -e ANTHROPIC_API_KEY=sk-ant-... ..."
    exit 1
fi

# --- Configure git (if env vars provided) ---
if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "${GIT_USER_NAME}"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "${GIT_USER_EMAIL}"
fi

# --- Start ttyd ---
TTYD_PORT="${TTYD_PORT:-7681}"
TTYD_CREDENTIAL="${TTYD_CREDENTIAL:-}"

echo ""
echo "Starting ttyd on port ${TTYD_PORT}..."
echo "Connect via: https://<host>:${TTYD_PORT}"
echo ""

# Build ttyd command
TTYD_ARGS=(
    ttyd
    --port "${TTYD_PORT}"
    --writable
)

# Add authentication if credentials are provided
if [ -n "${TTYD_CREDENTIAL}" ]; then
    TTYD_ARGS+=(--credential "${TTYD_CREDENTIAL}")
    echo "Authentication enabled."
else
    echo "WARNING: No TTYD_CREDENTIAL set — web terminal is unauthenticated."
    echo "Set TTYD_CREDENTIAL=user:password for production use."
fi

# Launch ttyd with bash as the shell
exec "${TTYD_ARGS[@]}" bash
