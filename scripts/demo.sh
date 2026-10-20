#!/usr/bin/env bash
# The thing you run before you start talking.
#   scripts/demo.sh            reset the morning, prove the lab is ready, start the checker's session
#   scripts/demo.sh reset      only reset and prove
# Run on the lab host. LAB_DIR is the agentlab directory (default /root/lab).
#
# The reset happens inside the running mock pods (POST /reset), so no pod restarts and
# muster keeps its connections. Restarting pods right before a demo left muster without
# a server for a few seconds, and an agent started in that window found the workflow
# "not available (missing required tools)".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="${LAB_DIR:-/root/lab}"
cd "$LAB"
export KUBECONFIG="$LAB/state/kubeconfig" AGENTLAB_NO_UPDATE_CHECK=1 DO_NOT_TRACK=1

echo "==> $(date +%H:%M:%S) reset in place: inbox back to 4 new emails, SAP without orders"
for d in mailbox-mock sap-mock; do
  kubectl -n bergmann exec "deploy/$d" -- python -c \
    "import urllib.request as u; print(u.urlopen(u.Request('http://127.0.0.1:8000/reset', method='POST')).read().decode())"
done

echo "==> $(date +%H:%M:%S) waiting for prove.sh to pass (servers, workflow through muster, refusal, portal)"
ok=0
for _ in $(seq 1 30); do
  if bash "$HERE/prove.sh" >/tmp/bergmann-prove.log 2>&1; then ok=1; break; fi
  sleep 4
done
if [[ $ok != 1 ]]; then
  echo "    NOT READY, last proof:"; cat /tmp/bergmann-prove.log; exit 1
fi
echo "    ready: $(grep -c '^PASS' /tmp/bergmann-prove.log) checks passed"
[[ "${1:-}" == "reset" ]] && exit 0

echo "==> $(date +%H:%M:%S) morning run: order-checker on the inbox (session kept, open it in the portal)"
agentlab turn --template order-checker --keep --events "$LAB/demo.events.jsonl" \
  "Good morning. Check all new dealer order emails in the inbox and write one check report per order." \
  | tee "$LAB/demo.out" | grep -E "^(session|state|elapsed|kept):" || true
echo "==> done. Portal: https://backstage.127.0.0.1.nip.io (admin@lab.local)"
