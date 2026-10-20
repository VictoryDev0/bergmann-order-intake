#!/usr/bin/env bash
# Deploy the Bergmann demo onto a running agentlab lab.
#   scripts/deploy.sh [--agents]      (--agents also applies the two HelmReleases;
#                                     needs GITHUB_OWNER and SKILLS_COMMIT exported)
# Needs: kubectl, KUBECONFIG pointing at the lab (agentlab writes state/kubeconfig).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> mock systems (namespace bergmann)"
kubectl apply -f platform/mocks.yaml >/dev/null
kubectl -n bergmann create configmap bergmann-mock-code --from-file=server.py=mocks/server.py \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n bergmann create configmap bergmann-mock-data --from-file=mocks/data \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n bergmann rollout restart deployment >/dev/null 2>&1 || true
kubectl -n bergmann rollout status deployment --timeout=180s

echo "==> MCP servers registered with muster"
kubectl apply -f platform/mcpservers.yaml
echo "==> workflow"
kubectl apply -f platform/workflow.yaml

if [[ "${1:-}" == "--agents" ]]; then
  : "${GITHUB_OWNER:?export GITHUB_OWNER}" "${SKILLS_COMMIT:?export SKILLS_COMMIT (full 40-char sha)}"
  echo "==> agents (skills pinned to $SKILLS_COMMIT)"
  for f in platform/agents/*.yaml; do
    sed -e "s/GITHUB_OWNER/$GITHUB_OWNER/g" -e "s/SKILLS_COMMIT/$SKILLS_COMMIT/g" "$f" | kubectl apply -f -
  done
fi

echo "==> state"
kubectl -n agent-platform get mcpservers.muster.giantswarm.io dealer-mailbox sap-erp mes-planning
kubectl -n agent-platform get workflows.muster.giantswarm.io validate-dealer-order
