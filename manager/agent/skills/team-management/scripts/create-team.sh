#!/bin/bash
# create-team.sh - Create a Team (Leader + Workers + Team Room)
#
# Usage:
#   create-team.sh --name <TEAM_NAME> --leader <LEADER_NAME> --workers <w1,w2,...> \
#     [--leader-model <MODEL>] [--worker-models <m1,m2,...>]
#
# Prerequisites:
#   - SOUL.md must exist for leader and each worker at /root/hiclaw-fs/agents/<NAME>/SOUL.md

set -e
source /opt/hiclaw/scripts/lib/hiclaw-env.sh
source /opt/hiclaw/scripts/lib/gateway-api.sh

log() {
    local msg="[hiclaw $(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "${msg}"
    if [ -w /proc/1/fd/1 ]; then
        echo "${msg}" > /proc/1/fd/1
    fi
}

_fail() {
    echo '{"error": "'"$1"'"}'
    exit 1
}

# ============================================================
# Parse arguments
# ============================================================
TEAM_NAME=""
LEADER_NAME=""
WORKERS_CSV=""
LEADER_MODEL=""
WORKER_MODELS_CSV=""

while [ $# -gt 0 ]; do
    case "$1" in
        --name)           TEAM_NAME="$2"; shift 2 ;;
        --leader)         LEADER_NAME="$2"; shift 2 ;;
        --workers)        WORKERS_CSV="$2"; shift 2 ;;
        --leader-model)   LEADER_MODEL="$2"; shift 2 ;;
        --worker-models)  WORKER_MODELS_CSV="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "${TEAM_NAME}" ] || [ -z "${LEADER_NAME}" ] || [ -z "${WORKERS_CSV}" ]; then
    echo "Usage: create-team.sh --name <TEAM> --leader <LEADER> --workers <w1,w2,...> [--leader-model MODEL] [--worker-models m1,m2,...]"
    exit 1
fi

# Parse workers list
IFS=',' read -ra WORKER_NAMES <<< "${WORKERS_CSV}"
IFS=',' read -ra WORKER_MODELS <<< "${WORKER_MODELS_CSV:-}"

MATRIX_DOMAIN="${HICLAW_MATRIX_DOMAIN:-matrix-local.hiclaw.io:8080}"
ADMIN_USER="${HICLAW_ADMIN_USER:-admin}"

log "=== Creating Team: ${TEAM_NAME} ==="
log "  Leader: ${LEADER_NAME}"
log "  Workers: ${WORKERS_CSV}"

# ============================================================
# Ensure credentials
# ============================================================
SECRETS_FILE="/data/hiclaw-secrets.env"
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
fi

if [ -z "${MANAGER_MATRIX_TOKEN:-}" ]; then
    MANAGER_PASSWORD="${HICLAW_MANAGER_PASSWORD:-}"
    if [ -z "${MANAGER_PASSWORD}" ]; then
        _fail "MANAGER_MATRIX_TOKEN not set and HICLAW_MANAGER_PASSWORD not available"
    fi
    MANAGER_MATRIX_TOKEN=$(curl -sf -X POST ${HICLAW_MATRIX_SERVER}/_matrix/client/v3/login \
        -H 'Content-Type: application/json' \
        -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"manager"},"password":"'"${MANAGER_PASSWORD}"'"}' \
        2>/dev/null | jq -r '.access_token // empty')
    if [ -z "${MANAGER_MATRIX_TOKEN}" ]; then
        _fail "Failed to obtain Manager Matrix token"
    fi
fi

# ============================================================
# Step 1: Create Team Leader
# ============================================================
log "Step 1: Creating Team Leader (${LEADER_NAME})..."
LEADER_ARGS=(--name "${LEADER_NAME}" --role team_leader --team "${TEAM_NAME}")
if [ -n "${LEADER_MODEL}" ]; then
    LEADER_ARGS+=(--model "${LEADER_MODEL}")
fi

LEADER_RESULT=$(bash /opt/hiclaw/agent/skills/worker-management/scripts/create-worker.sh "${LEADER_ARGS[@]}" 2>&1)
LEADER_JSON=$(echo "${LEADER_RESULT}" | sed -n '/---RESULT---/,$ p' | tail -n +2)
LEADER_ROOM_ID=$(echo "${LEADER_JSON}" | jq -r '.room_id // empty')

if [ -z "${LEADER_ROOM_ID}" ]; then
    log "  WARNING: Could not extract leader room_id from result"
    log "  Result: ${LEADER_RESULT}"
fi
log "  Leader created: room=${LEADER_ROOM_ID}"

# ============================================================
# Step 2: Create Team Workers
# ============================================================
log "Step 2: Creating team workers..."
WORKER_ROOM_IDS=()

for i in "${!WORKER_NAMES[@]}"; do
    w_name=$(echo "${WORKER_NAMES[$i]}" | tr -d ' ')
    [ -z "${w_name}" ] && continue

    w_model="${WORKER_MODELS[$i]:-}"
    log "  Creating worker: ${w_name}..."

    W_ARGS=(--name "${w_name}" --role worker --team "${TEAM_NAME}" --team-leader "${LEADER_NAME}")
    if [ -n "${w_model}" ]; then
        W_ARGS+=(--model "${w_model}")
    fi

    W_RESULT=$(bash /opt/hiclaw/agent/skills/worker-management/scripts/create-worker.sh "${W_ARGS[@]}" 2>&1)
    W_JSON=$(echo "${W_RESULT}" | sed -n '/---RESULT---/,$ p' | tail -n +2)
    W_ROOM_ID=$(echo "${W_JSON}" | jq -r '.room_id // empty')
    WORKER_ROOM_IDS+=("${W_ROOM_ID}")
    log "  Worker ${w_name} created: room=${W_ROOM_ID}"
done

# ============================================================
# Step 3: Create Team Room (Leader + Admin + all Workers)
# ============================================================
log "Step 3: Creating Team Room..."
MANAGER_MATRIX_ID="@manager:${MATRIX_DOMAIN}"
ADMIN_MATRIX_ID="@${ADMIN_USER}:${MATRIX_DOMAIN}"
LEADER_MATRIX_ID="@${LEADER_NAME}:${MATRIX_DOMAIN}"

# Build invite list: Admin + Leader + all workers
INVITE_LIST="\"${ADMIN_MATRIX_ID}\",\"${LEADER_MATRIX_ID}\""
for w_name in "${WORKER_NAMES[@]}"; do
    w_name=$(echo "${w_name}" | tr -d ' ')
    [ -z "${w_name}" ] && continue
    INVITE_LIST="${INVITE_LIST},\"@${w_name}:${MATRIX_DOMAIN}\""
done

# Build power levels: Leader=100, Admin=100, Workers=0
POWER_USERS="\"${MANAGER_MATRIX_ID}\": 100, \"${ADMIN_MATRIX_ID}\": 100, \"${LEADER_MATRIX_ID}\": 100"
for w_name in "${WORKER_NAMES[@]}"; do
    w_name=$(echo "${w_name}" | tr -d ' ')
    [ -z "${w_name}" ] && continue
    POWER_USERS="${POWER_USERS}, \"@${w_name}:${MATRIX_DOMAIN}\": 0"
done

# E2EE
ROOM_E2EE_INITIAL_STATE=""
if [ "${HICLAW_MATRIX_E2EE:-0}" = "1" ] || [ "${HICLAW_MATRIX_E2EE:-}" = "true" ]; then
    ROOM_E2EE_INITIAL_STATE=',"initial_state":[{"type":"m.room.encryption","state_key":"","content":{"algorithm":"m.megolm.v1.aes-sha2"}}]'
fi

TEAM_ROOM_RESP=$(curl -sf -X POST ${HICLAW_MATRIX_SERVER}/_matrix/client/v3/createRoom \
    -H "Authorization: Bearer ${MANAGER_MATRIX_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{
        "name": "Team: '"${TEAM_NAME}"'",
        "topic": "Team room for '"${TEAM_NAME}"' — Leader + Workers coordination",
        "invite": ['"${INVITE_LIST}"'],
        "preset": "trusted_private_chat",
        "power_level_content_override": {
            "users": {'"${POWER_USERS}"'}
        }'"${ROOM_E2EE_INITIAL_STATE}"'
    }' 2>/dev/null) || _fail "Failed to create Team Room"

TEAM_ROOM_ID=$(echo "${TEAM_ROOM_RESP}" | jq -r '.room_id // empty')
if [ -z "${TEAM_ROOM_ID}" ]; then
    _fail "Failed to create Team Room: ${TEAM_ROOM_RESP}"
fi
log "  Team Room created: ${TEAM_ROOM_ID}"

# ============================================================
# Step 4: Update Leader's groupAllowFrom to include all team workers
# ============================================================
log "Step 4: Updating Leader's groupAllowFrom..."
LEADER_CONFIG="/root/hiclaw-fs/agents/${LEADER_NAME}/openclaw.json"
if [ -f "${LEADER_CONFIG}" ]; then
    for w_name in "${WORKER_NAMES[@]}"; do
        w_name=$(echo "${w_name}" | tr -d ' ')
        [ -z "${w_name}" ] && continue
        W_MATRIX_ID="@${w_name}:${MATRIX_DOMAIN}"
        jq --arg w "${W_MATRIX_ID}" \
            'if (.channels.matrix.groupAllowFrom | index($w)) then .
             else .channels.matrix.groupAllowFrom += [$w]
             end' \
            "${LEADER_CONFIG}" > /tmp/leader-config-tmp.json
        mv /tmp/leader-config-tmp.json "${LEADER_CONFIG}"
    done
    log "  Leader groupAllowFrom updated with all team workers"

    # Push updated config to MinIO
    ensure_mc_credentials 2>/dev/null || true
    mc cp "${LEADER_CONFIG}" "${HICLAW_STORAGE_PREFIX}/agents/${LEADER_NAME}/openclaw.json" 2>/dev/null \
        || log "  WARNING: Failed to push leader config to MinIO"
fi

# ============================================================
# Step 5: Update teams-registry.json
# ============================================================
log "Step 5: Updating teams-registry.json..."
bash /opt/hiclaw/agent/skills/team-management/scripts/manage-teams-registry.sh \
    --action add \
    --team-name "${TEAM_NAME}" \
    --leader "${LEADER_NAME}" \
    --workers "${WORKERS_CSV}" \
    --team-room-id "${TEAM_ROOM_ID}"

# ============================================================
# Output JSON result
# ============================================================
WORKERS_JSON="[]"
for i in "${!WORKER_NAMES[@]}"; do
    w_name=$(echo "${WORKER_NAMES[$i]}" | tr -d ' ')
    [ -z "${w_name}" ] && continue
    w_room="${WORKER_ROOM_IDS[$i]:-}"
    WORKERS_JSON=$(echo "${WORKERS_JSON}" | jq --arg n "${w_name}" --arg r "${w_room}" '. += [{name: $n, room_id: $r}]')
done

RESULT=$(jq -n \
    --arg team "${TEAM_NAME}" \
    --arg leader "${LEADER_NAME}" \
    --arg leader_room "${LEADER_ROOM_ID}" \
    --arg team_room "${TEAM_ROOM_ID}" \
    --argjson workers "${WORKERS_JSON}" \
    '{
        team_name: $team,
        leader: $leader,
        leader_room_id: $leader_room,
        team_room_id: $team_room,
        workers: $workers
    }')

echo "---RESULT---"
echo "${RESULT}"
