#!/bin/bash
# local-k8s-up.sh — Create a kind cluster and deploy HiClaw via Helm.
#
# Prerequisites:
#   - kind: https://kind.sigs.k8s.io/
#   - helm: https://helm.sh/
#   - kubectl
#
# Required environment variables:
#   HICLAW_LLM_API_KEY          LLM API key
#
# Optional environment variables:
#   HICLAW_REGISTRATION_TOKEN   Matrix registration token (auto-generated if empty)
#   HICLAW_ADMIN_PASSWORD       Admin password (auto-generated if empty)
#   HICLAW_CLUSTER_NAME         kind cluster name (default: hiclaw)
#   HICLAW_NAMESPACE            K8s namespace (default: hiclaw)
#   HICLAW_SKIP_KIND            Skip kind cluster creation (default: 0)
#
# Usage:
#   HICLAW_LLM_API_KEY=sk-xxx ./hack/local-k8s-up.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME="${HICLAW_CLUSTER_NAME:-hiclaw}"
NAMESPACE="${HICLAW_NAMESPACE:-hiclaw}"
SKIP_KIND="${HICLAW_SKIP_KIND:-0}"

LLM_API_KEY="${HICLAW_LLM_API_KEY:-}"
REGISTRATION_TOKEN="${HICLAW_REGISTRATION_TOKEN:-}"
ADMIN_PASSWORD="${HICLAW_ADMIN_PASSWORD:-}"

log() { echo -e "\033[36m[HiClaw K8s]\033[0m $1"; }
error() { echo -e "\033[31m[HiClaw K8s ERROR]\033[0m $1" >&2; exit 1; }

# ── Preflight checks ──────────────────────────────────────────────────────

for cmd in kind helm kubectl; do
    command -v "$cmd" >/dev/null 2>&1 || error "$cmd is required but not found"
done

if [ -z "$LLM_API_KEY" ]; then
    error "HICLAW_LLM_API_KEY is required. Example: HICLAW_LLM_API_KEY=sk-xxx $0"
fi

# Auto-generate secrets if not provided
if [ -z "$REGISTRATION_TOKEN" ]; then
    REGISTRATION_TOKEN=$(openssl rand -hex 16)
    log "Auto-generated registration token: ${REGISTRATION_TOKEN}"
fi

if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
    log "Auto-generated admin password: ${ADMIN_PASSWORD}"
fi

# ── Step 1: Create kind cluster ───────────────────────────────────────────

if [ "$SKIP_KIND" = "0" ]; then
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log "kind cluster '${CLUSTER_NAME}' already exists, skipping creation"
    else
        log "Creating kind cluster '${CLUSTER_NAME}'..."
        kind create cluster --name "$CLUSTER_NAME" --config "${PROJECT_ROOT}/hack/kind-config.yaml"
    fi
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
else
    log "Skipping kind cluster creation (HICLAW_SKIP_KIND=1)"
fi

# ── Step 2: Build Helm dependencies ──────────────────────────────────────

CHART_DIR="${PROJECT_ROOT}/helm/hiclaw"

log "Building Helm dependencies..."
helm dependency build "$CHART_DIR" 2>/dev/null || true

# ── Step 3: Helm install / upgrade ────────────────────────────────────────

log "Installing HiClaw via Helm..."
helm upgrade --install hiclaw "$CHART_DIR" \
    --namespace "$NAMESPACE" --create-namespace \
    -f "${CHART_DIR}/values-kind.yaml" \
    --set credentials.registrationToken="$REGISTRATION_TOKEN" \
    --set credentials.adminPassword="$ADMIN_PASSWORD" \
    --set credentials.llmApiKey="$LLM_API_KEY" \
    --timeout 10m \
    --wait=false

# ── Step 4: Wait for core infrastructure ──────────────────────────────────

log "Waiting for Tuwunel..."
kubectl wait --for=condition=available deployment -l app.kubernetes.io/component=tuwunel \
    -n "$NAMESPACE" --timeout=120s 2>/dev/null || log "Tuwunel not ready yet (may still be pulling image)"

log "Waiting for MinIO..."
kubectl wait --for=condition=available deployment -l app.kubernetes.io/component=minio \
    -n "$NAMESPACE" --timeout=120s 2>/dev/null || log "MinIO not ready yet"

log "Waiting for Orchestrator..."
kubectl wait --for=condition=available deployment -l app.kubernetes.io/component=orchestrator \
    -n "$NAMESPACE" --timeout=120s 2>/dev/null || log "Orchestrator not ready yet"

# ── Step 5: Print access information ──────────────────────────────────────

echo ""
log "========================================="
log " HiClaw Local K8s Deployment"
log "========================================="
echo ""
log "Cluster:   kind-${CLUSTER_NAME}"
log "Namespace: ${NAMESPACE}"
echo ""
log "Admin credentials:"
log "  Username: admin"
log "  Password: ${ADMIN_PASSWORD}"
echo ""
log "Registration token: ${REGISTRATION_TOKEN}"
echo ""
log "Access Element Web:"
log "  kubectl port-forward svc/hiclaw-element-web 8080:8080 -n ${NAMESPACE}"
log "  Then open: http://localhost:8080"
echo ""
log "View Manager logs:"
log "  kubectl logs -f deployment/hiclaw-manager -n ${NAMESPACE}"
echo ""
log "View all pods:"
log "  kubectl get pods -n ${NAMESPACE}"
echo ""
