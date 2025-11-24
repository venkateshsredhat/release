#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"
az bicep install || true
az bicep version
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
az account show

kubectl version
kubelogin --version
export DEPLOY_ENV="prow"

PRINCIPAL_ID=$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id -o tsv)
export PRINCIPAL_ID
unset GOFLAGS

# Set target ACR
TARGET_ACR="arohcpsvcdev"
TARGET_ACR_LOGIN_SERVER="arohcpsvcdev.azurecr.io"


# Mirror backend image to ACR if needed
echo "Starting backend image mirroring process..."
BACKEND_DIGEST=$(echo ${BACKEND_IMAGE} | cut -d'@' -f2)
REPOSITORY=$(echo ${BACKEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
SOURCE_REGISTRY=$(echo ${BACKEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${SOURCE_REGISTRY} and repo ${REPOSITORY}"

# shortcut mirroring if the source registry is the same as the target ACR
ACR_DOMAIN_SUFFIX="$(az cloud show --query "suffixes.acrLoginServerEndpoint" --output tsv)"
if [[ "${SOURCE_REGISTRY}" == "${TARGET_ACR_LOGIN_SERVER}" ]]; then
    echo "Source and target registry are the same. No mirroring needed."
    FINAL_BACKEND_REPO="${BACKEND_REPO}"
    FINAL_BACKEND_DIGEST="${BACKEND_DIGEST}"
else
    echo "Mirroring from ${SOURCE_REGISTRY} to ${TARGET_ACR_LOGIN_SERVER}"

    # ACR login to target registry
    echo "Logging into target ACR ${TARGET_ACR}."
    if output="$( az acr login --name "${TARGET_ACR}" --expose-token --only-show-errors --output json 2>&1 )"; then
      RESPONSE="${output}"
    else
      echo "Failed to log in to ACR ${TARGET_ACR}: ${output}"
      exit 1
    fi

    # ORAS login with ACR token
    oras login --username 00000000-0000-0000-0000-000000000000 \
               --password-stdin \
               "${TARGET_ACR_LOGIN_SERVER}" <<<"$( jq --raw-output .accessToken <<<"${RESPONSE}" )"

    # Check for DRY_RUN
    if [ "${DRY_RUN:-false}" == "true" ]; then
        echo "DRY_RUN is enabled. Exiting without making changes."
        exit 0
    fi

    # mirror image using oras
    SRC_IMAGE="${BACKEND_IMAGE}"
    DIGEST_NO_PREFIX=${BACKEND_DIGEST#sha256:}
    TARGET_IMAGE="${TARGET_ACR_LOGIN_SERVER}/${REPOSITORY}:${DIGEST_NO_PREFIX}"
    echo "Mirroring image ${SRC_IMAGE} to ${TARGET_IMAGE}."
    echo "The image will still be available under it's original digest ${BACKEND_DIGEST} in the target registry."

    oras cp "${SRC_IMAGE}" "${TARGET_IMAGE}"

    # Update variables for override config to use ACR
    FINAL_BACKEND_REPO="${TARGET_ACR_LOGIN_SERVER}/${REPOSITORY}"
    FINAL_BACKEND_DIGEST="${BACKEND_DIGEST}"

     echo "final image ${FINAL_BACKEND_REPO} and ${FINAL_BACKEND_DIGEST}"
fi

# Set variables similar to your Makefile
export OVERRIDE_CONFIG_FILE=${OVERRIDE_CONFIG_FILE:-/tmp/backend-override-config-$(date +%s).yaml}
yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.repository = \"${FINAL_BACKEND_REPO}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.digest = \"${FINAL_BACKEND_DIGEST}\"
" > ${OVERRIDE_CONFIG_FILE}

echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat ${OVERRIDE_CONFIG_FILE}

export LOG_LEVEL=10
make entrypoint/Region TIMING_OUTPUT=${SHARED_DIR}/steps.yaml DEPLOY_ENV=prow LOG_LEVEL=10

make -C dev-infrastructure/ svc.aks.kubeconfig SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV=prow
export KUBECONFIG=kubeconfig
PIDFILE="/tmp/svc-tunnel.pid"
MONITOR_PIDFILE="/tmp/svc-monitor.pid"
NAMESPACE="aro-hcp"
SERVICE="aro-hcp-frontend"
LOCAL_PORT=8443
REMOTE_PORT=8443

wait_for_service() {
    for i in {1..5}; do
        if kubectl get svc -n "$NAMESPACE" "$SERVICE" >/dev/null 2>&1; then
            echo "Service $SERVICE found"
            return 0
        else
            echo "Service $SERVICE not found (attempt $i/5)"
            [[ $i -lt 5 ]] && sleep 10
        fi
    done
    echo "Service not available after 5 attempts, exiting"
    exit 1
}

start_port_forward() {
    echo "Starting port-forward..."
    pkill -f "kubectl.*port-forward.*$LOCAL_PORT" || true
    sleep 1
    kubectl port-forward -n "$NAMESPACE" "svc/$SERVICE" \
        "$LOCAL_PORT:$REMOTE_PORT" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 3
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Port forward running (PID: $(cat "$PIDFILE"))"
        return 0
    else
        echo "Port forward failed to start"
        rm -f "$PIDFILE"
        return 1
    fi
}

monitor_port_forward() {
    echo "Starting port-forward monitor..."
    while true; do
        if curl -s --connect-timeout 2 --max-time 3 "http://localhost:$LOCAL_PORT/" >/dev/null 2>&1; then
            sleep 5
        else
            echo "Port $LOCAL_PORT not responding, restarting port-forward..."
            if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
                kill "$(cat "$PIDFILE")" 2>/dev/null || true
                rm -f "$PIDFILE"
            fi
            if ! start_port_forward; then
                echo "Failed to restart port-forward, retrying in 10s..."
                sleep 10
            fi
        fi
    done
}

start_tunnel() {
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Port forward already running (PID: $(cat "$PIDFILE"))"
        return 0
    fi
    wait_for_service
    for attempt in {1..3}; do
        if start_port_forward; then
            break
        elif [[ $attempt -lt 3 ]]; then
            echo "Retrying port-forward start (attempt $((attempt + 1))/3)..."
            sleep 5
        else
            echo "Failed to start port-forward after 3 attempts"
            exit 1
        fi
    done

    monitor_port_forward &
    echo $! > "$MONITOR_PIDFILE"
    echo "Monitor started (PID: $(cat "$MONITOR_PIDFILE"))"
}

stop_tunnel() {
    if [[ -f "$MONITOR_PIDFILE" ]] && kill -0 "$(cat "$MONITOR_PIDFILE")" 2>/dev/null; then
        echo "Stopping monitor (PID: $(cat "$MONITOR_PIDFILE"))"
        kill "$(cat "$MONITOR_PIDFILE")" 2>/dev/null || true
    fi
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Stopping port forward (PID: $(cat "$PIDFILE"))"
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    # Clean up any remaining port-forwards
    pkill -f "kubectl.*port-forward.*$LOCAL_PORT" || true
    rm -f "$PIDFILE" "$MONITOR_PIDFILE" 2>/dev/null || true
    echo "Port forward stopped"
}

trap stop_tunnel EXIT

start_tunnel
make e2e/local -o test/aro-hcp-tests
stop_tunnel