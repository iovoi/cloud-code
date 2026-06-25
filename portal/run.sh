#!/usr/bin/env bash
set -euo pipefail
# Launch wrapper for the Claude chat portal. Fetches ANTHROPIC_API_KEY from
# GCP Secret Manager (same curl/metadata pattern as start.sh) so no key lives
# on disk, then runs the Node server.

ENV_FILE="/home/developer/.env"
PROJECT=""
KEY_SECRET=""
if [ -f "${ENV_FILE}" ]; then
    PROJECT="$(set -a; source "${ENV_FILE}"; echo "${GCP_PROJECT:-}")"
    KEY_SECRET="$(set -a; source "${ENV_FILE}"; echo "${ANTHROPIC_API_KEY_SECRET:-}")"
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -n "${KEY_SECRET}" ] && [ -n "${PROJECT}" ]; then
    TOKEN="$(curl -fsS -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
        | jq -r '.access_token // empty')" || TOKEN=""
    export ANTHROPIC_API_KEY="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
        "https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${KEY_SECRET}/versions/latest:access" \
        | jq -r '.payload.data // empty' | base64 -d)"
fi

export PATH="/home/developer/.nvm/versions/node/current/bin:${PATH}"
export WORKDIR="${WORKDIR:-/home/developer/workspace}"
export STORE_DIR="${STORE_DIR:-/home/developer/.claude-portal}"
export HOST="${HOST:-127.0.0.1}"
export PORT="${PORT:-3000}"

exec node "$(dirname "$0")/server.js"
