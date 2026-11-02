#!/bin/sh
# Installs the Helm chart with every values file in charts/*/ci/ into a namespace that ENFORCES
# Pod Security "restricted", and fails if Kubernetes rejects a pod or warns about one. Gateway API
# CRDs must be installed (ListenerSet and HTTPRoute are validated by the API server).
#
#   tests/chart-install.sh <kube-context> [image-tag]
#
# The pods are expected to crash-loop afterwards: the values point at fake Azure DevOps
# repositories. What's tested is that every manifest is accepted and every pod is admitted.
set -eu

CTX="${1:?usage: $0 <kube-context> [image-tag]}"
TAG="${2:-}"
CHART=charts/git-v2-azuredevops-proxy
NS="git-proxy-chart-test-$$"

kube() { kubectl --context "$CTX" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
    kube delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kube create namespace "$NS" >/dev/null
kube label namespace "$NS" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/audit=restricted >/dev/null
# Secrets the values files reference instead of letting the chart create them.
kube -n "$NS" create secret generic my-pat --from-literal=AZURE_PAT=not-a-real-pat >/dev/null
kube -n "$NS" create secret generic my-entra-secret --from-literal=secret=not-a-real-secret >/dev/null

expected=0
for values in "$CHART"/ci/*-values.yaml; do
    release=$(basename "$values" -values.yaml)
    echo "::group::helm install $release"
    out=$(helm --kube-context "$CTX" -n "$NS" install "$release" "$CHART" -f "$values" \
        --set persistence.existingClaim= ${TAG:+--set image.tag="$TAG"} 2>&1) \
        || { echo "$out"; fail "$release: helm install failed"; }
    echo "$out"
    echo "::endgroup::"
    if printf '%s' "$out" | grep -qi 'would violate PodSecurity'; then
        fail "$release: Pod Security warning"
    fi
    expected=$((expected + 1))
done

# Wait until every Deployment has created its pod - or Pod Security admission rejected it.
i=0
until [ "$(kube -n "$NS" get pods -l app.kubernetes.io/name=git-v2-azuredevops-proxy --no-headers 2>/dev/null | wc -l)" -ge "$expected" ]; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        kube -n "$NS" get events --field-selector reason=FailedCreate || true
        fail "not every pod was created"
    fi
    sleep 2
done

rejected=$(kube -n "$NS" get events --field-selector reason=FailedCreate --no-headers 2>/dev/null || true)
[ -z "$rejected" ] || fail "pods rejected: $rejected"

kube -n "$NS" get listenersets,httproutes,pods
echo "ok - $expected releases installed; every pod admitted under Pod Security 'restricted'"
