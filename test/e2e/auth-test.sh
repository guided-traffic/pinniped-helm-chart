#!/usr/bin/env bash
# End-to-end authentication test with synthetic credentials.
#
# Proves that a real user login against the kind cluster works:
#   pinniped CLI -> Supervisor (password grant against Dex) -> ID token
#   -> Concierge TokenCredentialRequest -> client certificate -> kubectl.
#
# Assertions:
#   1. `kubectl auth whoami` through the pinniped kubeconfig returns the
#      synthetic identity pinny@example.com.
#   2. RBAC positive: with a `view` ClusterRoleBinding the user can list pods.
#   3. RBAC negative: the same user cannot create pods.
#   4. Login with a wrong password fails.
#
# Idempotent — run once after setup-idp.sh and again after the SKE-mode
# upgrade to prove login still works with stackitSKE.enabled=true.
set -euo pipefail

ISSUER_HOST="pinniped-supervisor.pinniped.svc.cluster.local"
ISSUER_URL="https://${ISSUER_HOST}:8443/demo-issuer"
CERT_DIR="${CERT_DIR:-/tmp/pinniped-e2e-certs}"
PINNIPED_NAMESPACE="${PINNIPED_NAMESPACE:-pinniped}"
E2E_KUBECONFIG="/tmp/pinniped-e2e-kubeconfig.yaml"
E2E_USERNAME="pinny@example.com"
E2E_PASSWORD="password"

clear_cli_cache() {
  # The pinniped CLI caches sessions and cluster credentials; clear them so
  # every run exercises the full login flow instead of a cached credential.
  rm -rf "${HOME}/.config/pinniped" "${HOME}/.cache/pinniped"
}

echo "=== Making the issuer reachable from the runner ==="
if ! grep -q "${ISSUER_HOST}" /etc/hosts; then
  if [ -w /etc/hosts ]; then
    echo "127.0.0.1 ${ISSUER_HOST}" >> /etc/hosts
  else
    echo "127.0.0.1 ${ISSUER_HOST}" | sudo tee -a /etc/hosts
  fi
fi

kubectl -n "${PINNIPED_NAMESPACE}" port-forward svc/pinniped-supervisor 8443:8443 \
  > /tmp/pinniped-e2e-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

DISCOVERY_OK=false
for i in $(seq 1 30); do
  if curl -fsS --cacert "${CERT_DIR}/ca.crt" \
      "${ISSUER_URL}/.well-known/openid-configuration" > /dev/null 2>&1; then
    DISCOVERY_OK=true
    break
  fi
  sleep 2
done
if [ "${DISCOVERY_OK}" != "true" ]; then
  echo "ERROR: issuer discovery endpoint not reachable via port-forward"
  cat /tmp/pinniped-e2e-port-forward.log || true
  exit 1
fi
echo "Issuer discovery endpoint reachable."

echo "=== Generating pinniped kubeconfig ==="
clear_cli_cache
pinniped get kubeconfig \
  --oidc-ca-bundle "${CERT_DIR}/ca.crt" \
  --upstream-identity-provider-flow cli_password \
  > "${E2E_KUBECONFIG}"

echo "=== 1. Login with synthetic credentials, verify identity ==="
WHOAMI=$(PINNIPED_USERNAME="${E2E_USERNAME}" PINNIPED_PASSWORD="${E2E_PASSWORD}" \
  kubectl --kubeconfig "${E2E_KUBECONFIG}" auth whoami \
  -o jsonpath='{.status.userInfo.username}')
echo "authenticated as: ${WHOAMI}"
if [ "${WHOAMI}" != "${E2E_USERNAME}" ]; then
  echo "ERROR: expected username ${E2E_USERNAME}, got '${WHOAMI}'"
  exit 1
fi

echo "=== 2. RBAC positive: view role allows listing pods ==="
kubectl create clusterrolebinding pinniped-e2e-view \
  --clusterrole=view --user="${E2E_USERNAME}" \
  --dry-run=client -o yaml | kubectl apply -f -
PINNIPED_USERNAME="${E2E_USERNAME}" PINNIPED_PASSWORD="${E2E_PASSWORD}" \
  kubectl --kubeconfig "${E2E_KUBECONFIG}" get pods -n "${PINNIPED_NAMESPACE}"

echo "=== 3. RBAC negative: view role must not allow creating pods ==="
CAN_CREATE=$(PINNIPED_USERNAME="${E2E_USERNAME}" PINNIPED_PASSWORD="${E2E_PASSWORD}" \
  kubectl --kubeconfig "${E2E_KUBECONFIG}" auth can-i create pods \
  -n "${PINNIPED_NAMESPACE}" || true)
echo "can-i create pods: ${CAN_CREATE}"
if [ "${CAN_CREATE}" != "no" ]; then
  echo "ERROR: expected 'no', got '${CAN_CREATE}'"
  exit 1
fi

echo "=== 4. Login with wrong password must fail ==="
clear_cli_cache
if PINNIPED_USERNAME="${E2E_USERNAME}" PINNIPED_PASSWORD="definitely-wrong" \
    timeout 90 kubectl --kubeconfig "${E2E_KUBECONFIG}" auth whoami \
    > /tmp/pinniped-e2e-wrong-pw.log 2>&1; then
  echo "ERROR: login with wrong password unexpectedly succeeded"
  cat /tmp/pinniped-e2e-wrong-pw.log
  exit 1
fi
echo "Wrong password correctly rejected."

echo "All authentication e2e assertions passed."
