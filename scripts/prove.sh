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
hdr=(-H "Authorization: Bearer $T" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"prove","version":"0"}}}'
S=$(curl -sk -D - -o /dev/null "$M" "${hdr[@]}" -H "X-Muster-Toolset: preset:read-only,workflow:validate-dealer-order" -d "$init" | grep -i mcp-session-id | tr -d '\r' | cut -d' ' -f2)
[[ -n "$S" ]] && ok "muster session as admin (toolset read-only + workflow)" || bad "no muster session"
curl -sk "$M" "${hdr[@]}" -H "Mcp-Session-Id: $S" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
call() { curl -sk -m 120 "$M" "${hdr[@]}" -H "Mcp-Session-Id: $S" -H "X-Muster-Toolset: preset:read-only,workflow:validate-dealer-order" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"call_tool\",\"arguments\":{\"name\":\"$1\",\"arguments\":$2}}}" \
  | sed 's/^data: //' | grep '^{' | tail -1; }
r=$(call workflow_validate-dealer-order '{"email_id":"E-2026-10-26-002"}')
echo "$r" | grep -q completed && echo "$r" | grep -q 'BP-COMBI-10-G' \
  && ok "workflow run: completed, BP-COMBI-10G resolved to BP-COMBI-10-G" || bad "workflow run: $(echo "$r" | head -c 300)"
r=$(call x_sap-erp_create_sales_order '{"dealer_no":"D-10211","items":[{"article_no":"BS-1042","qty":1}],"requested_delivery_week":"2026-W48"}')
echo "$r" | grep -q 'outside the toolset' && ok "read-only toolset refuses create_sales_order (muster, no model)" || bad "write was not refused: $(echo "$r" | head -c 300)"
r=$(call x_sap-erp_list_sales_orders '{}')
echo "$r" | grep -q '"count' && ok "SAP mock answers (list_sales_orders)" || bad "SAP mock: $(echo "$r" | head -c 200)"

# 4. the portal
code=$(curl -sk -o /dev/null -w '%{http_code}' https://backstage.127.0.0.1.nip.io/)
[[ "$code" == "200" ]] && ok "portal answers 200" || bad "portal answers $code"

[[ $fail == 0 ]] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
