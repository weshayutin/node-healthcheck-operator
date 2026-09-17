#!/bin/bash
# local-run.sh — Replicate the Kind e2e GitHub Actions workflow locally
#
# Deploys SNR from quay.io and builds NHC from local source.
# Tools are cloned automatically.
#
# Usage:
#   ./hack/local-run.sh              # Full run (setup + build + deploy + test)
#   ./hack/local-run.sh --skip-setup # Skip cluster creation (reuse existing)
#   ./hack/local-run.sh --skip-build # Skip build and deploy (reuse existing)
#   ./hack/local-run.sh --teardown   # Tear down the cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NHC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${NHC_DIR}/.tools"

export DEPLOY_SNR_NAMESPACE="${DEPLOY_SNR_NAMESPACE:-snr-system}"
export DEPLOY_NHC_NAMESPACE="${DEPLOY_NHC_NAMESPACE:-k8s-test}"

# Clone or update .tools directory
if [ ! -d "${TOOLS_DIR}" ]; then
    git clone --depth 1 --branch testing-hang https://github.com/mpryc/medik8s-tools.git $TOOLS_DIR
else
    echo "Updating existing .tools directory..."
    (cd "${TOOLS_DIR}" && git fetch origin testing-hang && git reset --hard origin/testing-hang)
fi

# --- Configuration (mirrors GitHub Actions env) ---
export MEDIK8S_CLUSTER_NAME="${MEDIK8S_CLUSTER_NAME:-medik8s-ci}"

# Auto-detect or configure container tool
# Local uses rootless podman (CI uses rootful with sudo)
if [ -z "${CONTAINER_TOOL:-}" ]; then
    if command -v podman &>/dev/null; then
        export CONTAINER_TOOL=podman
        echo "✓ Using rootless podman"

        # Check if cpuset is delegated for rootless podman
        if [ "$(id -u)" != "0" ]; then
            CGROUP_SUBTREE="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control"
            if [ -f "${CGROUP_SUBTREE}" ] && ! grep -q 'cpuset' "${CGROUP_SUBTREE}" 2>/dev/null; then
                echo "⚠ Warning: cpuset cgroup not delegated"
                echo "  Kind worker nodes may fail to start"
                echo "  See setup.sh error message for fix if needed"
            fi
        fi
    elif command -v docker &>/dev/null; then
        export CONTAINER_TOOL=docker
        echo "✓ Using docker (podman not found)"
    else
        echo "Error: neither podman nor docker found in PATH"
        exit 1
    fi
fi
export CONTAINER_TOOL
export MEDIK8S_REGISTRY_NAME="${MEDIK8S_REGISTRY_NAME:-kind-registry}"
export MEDIK8S_REGISTRY_PORT="${MEDIK8S_REGISTRY_PORT:-5000}"
export IMAGE_REGISTRY="${IMAGE_REGISTRY:-${MEDIK8S_REGISTRY_NAME}:${MEDIK8S_REGISTRY_PORT}}"
export OPM_RENDER_FLAGS="${OPM_RENDER_FLAGS:---skip-tls-verify}"
export TOOLS_DIR

NHC_IMG="${IMAGE_REGISTRY}/node-healthcheck-operator:latest"
NHC_BUNDLE="${IMAGE_REGISTRY}/node-healthcheck-operator-bundle:latest"

SKIP_SETUP=false
SKIP_BUILD=false
TEARDOWN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-setup) SKIP_SETUP=true; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --teardown)   TEARDOWN=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--skip-setup] [--skip-build] [--teardown]"
            echo ""
            echo "Replicates the Kind e2e GitHub Actions workflow locally."
            echo ""
            echo "Options:"
            echo "  --skip-setup   Skip cluster creation (reuse existing)"
            echo "  --skip-build   Skip build and deploy (reuse existing images/deployment)"
            echo "  --teardown     Tear down the cluster and exit"
            echo ""
            echo "Environment variables:"
            echo "  MEDIK8S_CLUSTER_NAME    Kind cluster name (default: medik8s-ci)"
            echo "  CONTAINER_TOOL          Container tool (default: docker)"
            echo "  DEPLOY_SNR_NAMESPACE    Namespace for SNR operator (default: snr-system)"
            echo "  DEPLOY_NHC_NAMESPACE    Namespace for NHC operator (default: k8s-test)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Validate local directories ---
if [ ! -d "${TOOLS_DIR}" ]; then
    echo "Error: Tools directory not found at ${TOOLS_DIR}"
    echo "Expected standard layout: upstream/shared/tools"
    exit 1
fi

echo "=== Local repositories ==="
echo "  NHC:   ${NHC_DIR}"
echo "         branch: $(cd "${NHC_DIR}" && git branch --show-current)"
echo "         commit: $(cd "${NHC_DIR}" && git log --oneline -1)"
echo "  Tools: ${TOOLS_DIR}"
echo "         branch: $(cd "${TOOLS_DIR}" && git branch --show-current)"
echo "         commit: $(cd "${TOOLS_DIR}" && git log --oneline -1)"
echo ""

step() {
    echo ""
    echo "========================================"
    echo "  $1"
    echo "========================================"
}

image_exists() {
    "${CONTAINER_TOOL}" image inspect "$1" >/dev/null 2>&1
}

check_and_cleanup_existing_build() {
    local found=false
    local image

    echo "=== Checking for existing local build artifacts ==="
    for image in "${NHC_IMG}" "${NHC_BUNDLE}"; do
        if image_exists "${image}"; then
            echo "  Found image: ${image}"
            found=true
        fi
    done

    if [ "${found}" = true ]; then
        echo "  Removing existing local operator images..."
        for image in "${NHC_IMG}" "${NHC_BUNDLE}"; do
            "${CONTAINER_TOOL}" image rm -f "${image}" >/dev/null 2>&1 || true
        done
        echo "  Existing local build artifacts removed."
    else
        echo "  No existing local operator images found."
    fi
}

deployed_resources() {
    kubectl get subscriptions,csv,deployments -n "${DEPLOY_SNR_NAMESPACE}" -o name 2>/dev/null | grep -E 'self-node-remediation' || true
    kubectl get subscriptions,csv,deployments -n "${DEPLOY_NHC_NAMESPACE}" -o name 2>/dev/null | grep -E 'node-healthcheck-operator' || true
}

check_and_cleanup_existing_deployment() {
    local resources

    echo "=== Checking for existing operator deployments ==="
    resources="$(deployed_resources)"
    if [ -z "${resources}" ]; then
        echo "  No existing SNR/NHC deployment found in namespaces."
        return
    fi

    echo "  Found existing resources:"
    echo "${resources}" | sed 's/^/    /'
    echo "  Removing existing OLM installations..."

    operator-sdk -n "${DEPLOY_SNR_NAMESPACE}" cleanup self-node-remediation || true
    operator-sdk -n "${DEPLOY_NHC_NAMESPACE}" cleanup node-healthcheck-operator --delete-all || true

    resources="$(deployed_resources)"
    if [ -n "${resources}" ]; then
        echo "  Warning: some SNR/NHC resources remain after cleanup:"
        echo "${resources}" | sed 's/^/    /'
    else
        echo "  Existing SNR/NHC deployment removed."
    fi
}

# --- Teardown ---
if [ "${TEARDOWN}" = true ]; then
    step "Tearing down cluster"
    cd "${NHC_DIR}"
    make dev-teardown 2>/dev/null || true
    exit 0
fi

# --- Setup ---
if [ "${SKIP_SETUP}" = false ]; then
    step "Installing operator-sdk"
    cd "${NHC_DIR}"
    make operator-sdk
    export PATH="${NHC_DIR}/bin:${PATH}"

    step "Creating Kind cluster with registry, OLM, and cert-manager"
    cd "${NHC_DIR}"
    make dev-setup

    step "Cluster info"
    cd "${NHC_DIR}"
    make dev-cluster-info
else
    echo "Skipping setup (--skip-setup)"
    export PATH="${NHC_DIR}/bin:${PATH}"
fi

# --- Build and deploy ---
if [ "${SKIP_BUILD}" = false ]; then
    check_and_cleanup_existing_build
    check_and_cleanup_existing_deployment

    step "Deploying SNR from quay.io"
    cd "${NHC_DIR}"
    kubectl create ns ${DEPLOY_SNR_NAMESPACE} 2>/dev/null || true
    kubectl label --overwrite ns ${DEPLOY_SNR_NAMESPACE} \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged
    operator-sdk run bundle -n ${DEPLOY_SNR_NAMESPACE} \
        --timeout 5m \
        quay.io/medik8s/self-node-remediation-operator-bundle:latest

    step "Building and pushing NHC"
    cd "${NHC_DIR}"
    export NHC_SKIP_TEST=true
    make container-build-k8s

    # Push to local registry (rootless podman)
    podman push --tls-verify=false ${NHC_IMG}
    podman push --tls-verify=false ${NHC_BUNDLE}

    step "Deploying NHC via OLM bundle"
    cd "${NHC_DIR}"
    kubectl create ns ${DEPLOY_NHC_NAMESPACE} 2>/dev/null || true
    kubectl label --overwrite ns ${DEPLOY_NHC_NAMESPACE} \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged
    operator-sdk run bundle -n ${DEPLOY_NHC_NAMESPACE} --use-http \
        --timeout 5m \
        ${IMAGE_REGISTRY}/node-healthcheck-operator-bundle:latest

    # Patch NHC immediately to move it to the control plane
    kubectl patch deployment node-healthcheck-controller-manager -n ${DEPLOY_NHC_NAMESPACE} -p '{"spec": {"template": {"spec": {"nodeSelector": {"node-role.kubernetes.io/control-plane": ""}, "tolerations": [{"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"}]}}}}' || true
    
    echo "Waiting 60s for operators to reschedule to control plane and stabilize..."
    sleep 60
else
    echo "Skipping build (--skip-build)"
fi

# --- Wait and verify ---
step "Waiting for deployments"
cd "${NHC_DIR}"
make dev-wait

step "Deployment status"
cd "${NHC_DIR}"
make dev-describe

# --- Run tests ---
step "Running e2e tests"
cd "${NHC_DIR}"

step "Starting reboot watcher"
export MEDIK8S_REBOOT_DELAY=90
make dev-reboot-watcher

OPERATOR_NS=${DEPLOY_NHC_NAMESPACE} \
SNR_STRATEGY=OutOfServiceTaint \
LABEL_FILTER='!OCP-ONLY' \
make test-e2e || {
    step "Debug (test failed)"
    make dev-ci-debug
    exit 1
}

echo ""
echo "========================================"
echo "  All tests passed!"
echo "========================================"
