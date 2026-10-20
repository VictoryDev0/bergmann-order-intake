# Build log

Running notes of how this demo was built, including where AI assistance did the work. Times are CEST.

## 2026-10-20 (evening)

- Read the hiring task and Dominik's Product Owner notes. Picked **dealer PDF order intake → on-time delivery (Pro)**: the metric leadership feels (87 % vs 95 % target), the cause is named (two clerks retype PDF order forms into SAP, errors are the most common cause of late Pro deliveries), the scope is narrow. Rejected the CEO's marketing-copy idea (moves none of the five metrics) and parked Home returns (Induct 80, 18 %) as phase two.
- Mac has no Docker and 21 GB free disk; chose a throwaway DigitalOcean droplet (4 vCPU / 8 GB, FRA1) instead. agentlab's floor is 4 CPU / 5.8 GiB, so it fits with ~0.6 CPU to spare.
- Claude Code wrote the mock systems and synthetic data from the customer profile; I decided which errors the four demo orders carry (one of each error class the back office sees).

## 2026-10-21

- 00:10 `agentlab configure --defaults` on the droplet, then two `extraModels` via OpenRouter (Sonnet 5.5, Haiku 5.5) because the default Anthropic path needs a direct Anthropic key.
- 00:15 `agentlab up --trust=false --open=false` in tmux (log: /root/lab/up.log). Preflight: "docker: 4 CPUs, 7.8 GiB; the lab requests 3.39 CPUs / 4.5 GiB … tight: 0.61 CPUs left".
- 00:20 kubectl 1.37 and uv installed on the droplet.
- 00:30 Repo skeleton. `mocks/server.py` (FastMCP, SYSTEM=mailbox|sap|mes) and `mocks/data/*.json`. Every tool returns a structured result and never raises, so a muster workflow can chain them.
- 00:55 Mocks verified locally with a FastMCP client: readOnlyHint set on all reads, the four demo orders produce the intended findings (dealer-number mismatch, article typo resolved to BP-COMBI-10-G, 2025 price recognised, pack size 10, week 46 not feasible on line 2 → week 47).
- 01:05 Written: platform/workflow.yaml (validate-dealer-order), mcpservers.yaml, mocks.yaml, scripts/deploy.sh, skills/dealer-order-intake, skills/home-returns-triage (phase two), agents order-checker (read-only) and order-booker (requireApproval).
- 01:10 `agentlab up` at minute 5: observability installed, side-loading platform images. Memory 5.9 GB available, load 6 on 4 vCPU.
- 01:20 Public repo github.com/VictoryDev0/bergmann-order-intake (skills must be fetchable by the agent's golden boot, pinned to a full commit). Commit identity fixed to the VictoryDev0 noreply address.
- 01:40 Third model config: gemini-3.6-flash (provider Gemini) for cheap trial runs; Sonnet 5.5 stays the demo model. `agentlab platform` applies it after `up`.
- 01:50 `up` stalled at Kyverno: node CPU requests at 98 % (four kagent Substrate workers reserve 1 CPU), the admission controller's 100m could not schedule. Trimmed requests of kube-state-metrics (200m → 20m) and kagent-ui (100m → 20m) with kubectl patch; Kyverno scheduled within seconds. Lesson for the talk: on a 4-CPU box the platform's own requests are the constraint, not the agents. A real Bergmann cluster would not have this problem; a first-time Kubernetes team sizing a pilot cluster would.
