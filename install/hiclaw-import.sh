#!/bin/bash
# hiclaw-import.sh - Import Worker/Team/Human resources into HiClaw
#
# Thin shell that delegates to the `hiclaw` CLI inside the Manager container.
# Supports both legacy ZIP packages and declarative YAML files.
#
# Usage:
#   ./hiclaw-import.sh --zip <path-or-url> [--yes]
#   ./hiclaw-import.sh -f <resource.yaml> [--prune] [--dry-run]
#
# Environment variables (for automation):
#   HICLAW_IMPORT_ZIP            Path or URL to Worker package ZIP
#   HICLAW_NON_INTERACTIVE       Skip all prompts (same as --yes)

set -e

# ============================================================
# Parse arguments
# ============================================================

ZIP_FILE="${HICLAW_IMPORT_ZIP:-}"
WORKER_NAME="${HICLAW_IMPORT_WORKER_NAME:-}"
AUTO_YES="${HICLAW_NON_INTERACTIVE:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --zip)  ZIP_FILE="$2"; shift 2 ;;
        --name) WORKER_NAME="$2"; shift 2 ;;
        --yes)  AUTO_YES=1; shift ;;
        -f|--file)
            # YAML declarative mode — delegate to hiclaw-apply.sh
            SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
            exec bash "${SCRIPT_DIR}/hiclaw-apply.sh" -f "$2" "${@:3}"
            ;;
        -h|--help)
            echo "Usage: $0 --zip <path-or-url> --name <worker-name> [--yes]"
            echo "       $0 -f <resource.yaml> [--prune] [--dry-run]  (declarative YAML mode)"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "${ZIP_FILE}" ] || [ -z "${WORKER_NAME}" ]; then
    echo "Usage: $0 --zip <path-or-url> --name <worker-name> [--yes]"
    echo "       $0 -f <resource.yaml> [--prune] [--dry-run]  (declarative YAML mode)"
    exit 1
fi

# ============================================================
# Delegate --zip to container-internal hiclaw CLI
# ============================================================

# Detect container runtime
CONTAINER_CMD=""
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    CONTAINER_CMD="docker"
elif command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    CONTAINER_CMD="podman"
fi
if [ -z "${CONTAINER_CMD}" ]; then
    echo "ERROR: Neither docker nor podman found" >&2
    exit 1
fi

# Verify Manager container
if ! ${CONTAINER_CMD} ps --filter name=hiclaw-manager --format '{{.Names}}' 2>/dev/null | grep -q 'hiclaw-manager'; then
    echo "ERROR: hiclaw-manager container is not running" >&2
    exit 1
fi

# Handle URL: download ZIP first
if echo "${ZIP_FILE}" | grep -qE '^https?://'; then
    echo "[HiClaw Import] Downloading ${ZIP_FILE}..."
    DOWNLOADED_ZIP=$(mktemp /tmp/hiclaw-import-XXXXXX.zip)
    curl -fSL -o "${DOWNLOADED_ZIP}" "${ZIP_FILE}" || { echo "ERROR: Download failed"; exit 1; }
    ZIP_FILE="${DOWNLOADED_ZIP}"
    trap 'rm -f "${DOWNLOADED_ZIP}"' EXIT
fi

# Copy ZIP into container
ZIP_BASENAME=$(basename "${ZIP_FILE}")
${CONTAINER_CMD} exec hiclaw-manager mkdir -p /tmp/import 2>/dev/null || true
${CONTAINER_CMD} cp "${ZIP_FILE}" "hiclaw-manager:/tmp/import/${ZIP_BASENAME}"
echo "[HiClaw Import] Copied ${ZIP_BASENAME} → container:/tmp/import/"

# Delegate to hiclaw apply --zip --name inside container
HICLAW_ARGS=("apply" "--zip" "/tmp/import/${ZIP_BASENAME}" "--name" "${WORKER_NAME}")
if [ "${AUTO_YES}" = "1" ]; then
    HICLAW_ARGS+=("--yes")
fi

exec ${CONTAINER_CMD} exec hiclaw-manager hiclaw "${HICLAW_ARGS[@]}"
