# Cloptima AI gateway examples (Node)

Each script in `src/examples/` is independent and self-contained: it creates its own policy, virtual key, and binding using the official `openai` and `@anthropic-ai/sdk` packages - no Cloptima-specific SDK required for inference - then runs its scenario and prints what happened. Run any single one in isolation; none of them depend on another having run first.

## Setup

Requires **Node.js 18+** (needed for native global `fetch` support) and npm:

```bash
node --version # verify Node.js 18+ is active
npm install
cp .env.example .env   # fill in CLOPTIMA_AI_ADMIN_KEY
```

Short on time? See [`../README.md`](../README.md#suggested-tour-10-minutes) for a suggested 7-script run order.

## Examples

| Command | What it shows |
| --- | --- |
| `npm run quickstart-openai` | Simplest working call, using the OpenAI SDK. |
| `npm run quickstart-anthropic` | Same, using the Anthropic SDK's own calling convention. |
| `npm run multi-model` | One policy allowlisting several Vertex AI Gemini model variants, called through it to compare cost and latency. |
| `npm run rate-limit` | A realistic per-minute request cap tripping after several calls. |
| `npm run token-limit` | A realistic output-token cap blocking a too-long request pre-flight. |
| `npm run budget-limit` | A small daily spend cap admitting several calls, then denying the rest. |
| `npm run agentic-runaway` | Retry/loop-iteration limits catching a simulated runaway agent loop. |
| `npm run pii-guardrail` | A model generates fake PII live, then a guardrail-enforced key blocks it. |
| `npm run exact-semantic-cache` | Exact-cache (enforce) and semantic-cache (observe) evidence. |
| `npm run provider-deny` | A non-Vertex model request blocked by a Vertex-only policy. |
| `npm run metadata-deny` | A deliberately unscoped key with no attribution headers, blocked. |
| `npm run byok` | Bring your own provider credential and route it through Cloptima's governance layer (needs `PROVIDER_API_KEY` in `.env`). |
| `npm run unit-economics-roi` | A cost-center agent (ROI vs. a pre-LLM baseline) and a profit-center agent (real booked revenue) side by side, each with its own computed report. |
| `npm run contract-pricing` | Seed a negotiated-rate price sheet and commitment, then read back retail vs. contracted vs. effective cost. |
| `npm run semantic-cache-enforce` | Semantic-cache enforce mode: the per-(app, route, model) class approval it needs, plus immediate enforcement and the applied governance-queue record. |
| `npm run approval-workflow` | Request a manual budget-change approval, show one request pending, then apply a second request immediately through the generic governance queue. |
| `npm run guardrail-detector-categories` | Baseline guardrail categories (prompt injection, jailbreak, toxicity) plus the Enterprise-gated custom detector + third-party provider integration. |
| `npm run guardrail-cost-governance` | A per-request guardrail cost cap tripping the cost-exceeded downgrade-to-lightweight action. |
| `npm run adaptive-routing` | Adaptive routing in observe mode across cheap/balanced/strong candidate model tiers. |
| `npm run prompt-release-workflow` | Prompt template, version, automated eval, quality gating, and release approval - demonstrating failed-gate block and successful activation via applyImmediately. |
| `npm run mcp-tool-governance` | A newly registered MCP tool server defaulting to 'disabled' pending review, plus the separate never-auto-approve rule. |

Each script prints illustrative policy limits it's using and says plainly that they're a starting point, not a fixed platform requirement - change the constant at the top of any script and re-run it.

## How the gateway calls work

- The gateway URL is already built into `src/lib/config.mjs` - you don't need to know or set it.
- OpenAI-style client points at `<gateway>/v1/ai` (the SDK appends `/chat/completions`).
- Anthropic-style client points at the gateway root (the SDK appends `/v1/messages`).
- Both send the virtual key as their normal API key - no custom auth code needed.
- Attribution and agent-context metadata ride as `x-cloptima-*` request headers (see `../docs/ENVIRONMENT.md`).
- There is no client-side cache toggle - exact/semantic caching is entirely policy-driven server-side (see `../docs/CACHE_AND_POLICY.md`).
- Policy/key/binding creation goes through the public `createLLMGatewayPolicy` / `createLLMGatewayKey` / `createLLMGatewayPolicyBinding` GraphQL mutations - see `src/lib/gatewayAdmin.mjs`.
