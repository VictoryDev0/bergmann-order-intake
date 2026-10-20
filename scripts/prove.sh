#!/usr/bin/env bash
# Proofs, not hope: one command that says whether the demo is ready.
# Run on the lab host in the agentlab directory (needs agentlab.yaml, state/kubeconfig).
#   scripts/prove.sh
set -uo pipefail
LAB="${LAB_DIR:-/root/lab}"
cd "$LAB"
export KUBECONFIG="$LAB/state/kubeconfig" AGENTLAB_NO_UPDATE_CHECK=1 DO_NOT_TRACK=1
M="https://muster.127.0.0.1.nip.io/mcp"
fail=0
ok()   { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fail=1; }

# 1. mocks and registration
for s in dealer-mailbox sap-erp mes-planning; do
  st=$(kubectl -n agent-platform get mcpserver.muster.giantswarm.io "$s" -o jsonpath='{.status.state}' 2>/dev/null)
  [[ "$st" == "Connected" ]] && ok "MCPServer $s Connected" || bad "MCPServer $s is '$st'"
done
v=$(kubectl -n agent-platform get workflow.muster.giantswarm.io validate-dealer-order -o jsonpath='{.status.valid}' 2>/dev/null)
[[ "$v" == "true" ]] && ok "workflow validate-dealer-order valid" || bad "workflow invalid: $v"

# 2. agents
for a in order-checker order-booker; do
  r=$(kubectl -n kagent get agents.api.kagent.dev "$a" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$r" == "True" ]] && ok "agent $a Ready" || bad "agent $a not Ready ($r)"
done

# 3. muster as the admin: a session, the workflow, the toolset refusal
agentlab login admin@lab.local >/dev/null 2>&1 || bad "agentlab login"
T=$(cat .token)
# the checker's own toolset, exactly as its HelmRelease declares it
TS=$(kubectl -n kagent get helmrelease order-checker -o jsonpath='{.spec.values.toolset}' \
     | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)))')
hdr=(-H "Authorization: Bearer $T" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"prove","version":"0"}}}'
S=$(curl -sk -D - -o /dev/null "$M" "${hdr[@]}" -H "X-Muster-Toolset: $TS" -d "$init" | grep -i mcp-session-id | tr -d '\r' | cut -d' ' -f2)
[[ -n "$S" ]] && ok "muster session as admin with the checker's toolset" || bad "no muster session"
curl -sk "$M" "${hdr[@]}" -H "Mcp-Session-Id: $S" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
call() { curl -sk -m 120 "$M" "${hdr[@]}" -H "Mcp-Session-Id: $S" -H "X-Muster-Toolset: $TS" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"call_tool\",\"arguments\":{\"name\":\"$1\",\"arguments\":$2}}}" \
  | sed 's/^data: //' | grep '^{' | tail -1; }
r=$(call workflow_validate-dealer-order '{"email_id":"E-2026-10-26-002"}')
wf=$(printf '%s' "$r" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); t=d["result"]["content"][0]["text"]; inner=json.loads(t); w=json.loads(inner["content"][0]["text"])
    steps=w.get("steps",[]); ok=w.get("status")=="completed" and all(s.get("status")=="completed" for s in steps)
    art=any("BP-COMBI-10-G" in json.dumps(s.get("result",{})) for s in steps if s.get("id")=="material")
    print(("OK" if ok and art else "BAD")+" status=%s steps=%d" % (w.get("status"), len(steps)))
except Exception as e: print("BAD parse: %s" % e)')
[[ "$wf" == OK* ]] && ok "workflow run: $wf, BP-COMBI-10G resolved to BP-COMBI-10-G" || bad "workflow run: $wf $(printf '%s' "$r" | head -c 200)"
r=$(call x_sap-erp_create_sales_order '{"dealer_no":"D-10211","items":[{"article_no":"BS-1042","qty":1}],"requested_delivery_week":"2026-W48"}')
echo "$r" | grep -q 'outside the toolset' && ok "checker's toolset refuses create_sales_order (muster, no model)" || bad "write was not refused: $(echo "$r" | head -c 300)"
r=$(call x_kubernetes_list '{"management_cluster":"agentlab","resourceType":"namespaces"}')
echo "$r" | grep -q 'outside the toolset' && ok "checker's toolset refuses Kubernetes reads too" || bad "kubernetes read was not refused: $(echo "$r" | head -c 200)"
r=$(call x_dealer-mailbox_list_order_emails '{"status":"all"}')
echo "$r" | grep -q '"count' && ok "inbox answers inside the toolset (list_order_emails)" || bad "inbox: $(echo "$r" | head -c 200)"

# 4. the portal
code=$(curl -sk -o /dev/null -w '%{http_code}' https://backstage.127.0.0.1.nip.io/)
[[ "$code" == "200" ]] && ok "portal answers 200" || bad "portal answers $code"

[[ $fail == 0 ]] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
