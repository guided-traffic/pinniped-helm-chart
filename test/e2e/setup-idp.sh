#!/usr/bin/env bash
# Deploys the mock IdP (Dex) and wires Pinniped up to it:
#   1. Generate a throwaway CA + serving certs for Dex and the Supervisor.
#   2. Deploy Dex with a synthetic static user (see dex.yaml).
#   3. helm upgrade the chart with OIDCIdentityProvider, FederationDomain,
#      client-credentials Secret and JWTAuthenticator (values-auth.tpl.yaml).
#   4. Wait until all Pinniped custom resources report phase Ready.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHART_DIR="${SCRIPT_DIR}/../../charts/pinniped"
CERT_DIR="${CERT_DIR:-/tmp/pinniped-e2e-certs}"
PINNIPED_NAMESPACE="${PINNIPED_NAMESPACE:-pinniped}"

echo "=== Generating throwaway CA and serving certificates ==="
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
  -keyout ca.key -out ca.crt -subj "/CN=pinniped-e2e-ca" 2>/dev/null

gen_cert() {
  local name="$1" cn="$2"
  openssl req -newkey rsa:2048 -nodes -keyout "${name}.key" \
    -out "${name}.csr" -subj "/CN=${cn}" 2>/dev/null
  openssl x509 -req -in "${name}.csr" -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out "${name}.crt" -days 2 -sha256 \
    -extfile <(printf "subjectAltName=DNS:%s" "${cn}") 2>/dev/null
}
gen_cert dex dex.dex.svc.cluster.local
gen_cert supervisor pinniped-supervisor.pinniped.svc.cluster.local

echo "=== Deploying Dex (mock OIDC IdP) ==="
kubectl create namespace dex --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dex create secret tls dex-tls \
  --cert=dex.crt --key=dex.key \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/dex.yaml"
kubectl -n dex rollout status deployment/dex --timeout=180s

echo "=== Creating supervisor serving-certificate secret ==="
kubectl -n "${PINNIPED_NAMESPACE}" create secret tls supervisor-tls \
  --cert=supervisor.crt --key=supervisor.key \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Upgrading chart with IdP, FederationDomain and JWTAuthenticator ==="
CA_B64=$(base64 < ca.crt | tr -d '\n')
sed "s|__E2E_CA_B64__|${CA_B64}|g" \
  "${SCRIPT_DIR}/values-auth.tpl.yaml" > "${CERT_DIR}/values-auth.yaml"

helm upgrade pinniped "${CHART_DIR}" \
  --namespace "${PINNIPED_NAMESPACE}" \
  --reuse-values \
  -f "${CERT_DIR}/values-auth.yaml" \
  --wait \
  --timeout 180s

echo "=== Waiting for Pinniped custom resources to become Ready ==="
wait_phase() {
  local kind="$1" name="$2"
  shift 2
  local phase=""
  for i in $(seq 1 36); do
    phase=$(kubectl get "${kind}" "${name}" "$@" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${phase}" = "Ready" ]; then
      echo "${kind}/${name}: Ready"
      return 0
    fi
    echo "attempt ${i}/36: ${kind}/${name} phase='${phase}', retrying..."
    sleep 5
  done
  echo "ERROR: ${kind}/${name} never became Ready"
  kubectl get "${kind}" "${name}" "$@" -o yaml || true
  return 1
}

wait_phase oidcidentityprovider dex -n "${PINNIPED_NAMESPACE}"
wait_phase federationdomain demo -n "${PINNIPED_NAMESPACE}"
wait_phase jwtauthenticator supervisor-jwt

echo "Mock IdP wired up, all Pinniped resources Ready."
