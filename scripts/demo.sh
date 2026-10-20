#!/usr/bin/env bash
# The thing you run before you start talking.
#   scripts/demo.sh            reset the morning inbox and start the checker's session
#   scripts/demo.sh reset      only reset (restart the mocks: inbox back to 4 new emails, SAP without orders)
# Run on the lab host, in the agentlab directory (needs agentlab.yaml there).
set -euo pipefail
LAB="${LAB_DIR:-/root/lab}"
cd "$LAB"
export KUBECONFIG="$LAB/state/kubeconfig" AGENTLAB_NO_UPDATE_CHECK=1 DO_NOT_TRACK=1

echo "==> $(date +%H:%M:%S) reset: inbox back to 4 new emails, SAP without orders"
kubectl -n bergmann rollout restart deployment mailbox-mock sap-mock >/dev/null
kubectl -n bergmann rollout status deployment mailbox-mock --timeout=120s >/dev/null
kubectl -n bergmann rollout status deployment sap-mock --timeout=120s >/dev/null
# muster reconnects on its own within its retry window; nudge it so the demo does not wait
for s in dealer-mailbox sap-erp; do
  kubectl -n agent-platform patch mcpserver.muster.giantswarm.io "$s" --type merge \
    -p "{\"spec\":{\"restartRequestedAt\":\"$(date -u +%FT%TZ)\"}}" >/dev/null
done
until [[ "$(kubectl -n agent-platform get mcpserver.muster.giantswarm.io sap-erp -o jsonpath='{.status.state}')" == "Connected" ]]; do sleep 2; done
echo "    mocks connected"
[[ "${1:-}" == "reset" ]] && exit 0

echo "==> $(date +%H:%M:%S) morning run: order-checker on the inbox (session kept, open it in the portal)"
agentlab turn --template order-checker --keep --events "$LAB/demo.events.jsonl" \
  "Good morning. Check all new dealer order emails in the inbox and write one check report per order." \
  | tee "$LAB/demo.out" | grep -E "^(session|state|elapsed|kept):" || true
echo "==> done. Portal: https://backstage.127.0.0.1.nip.io (admin@lab.local)"
