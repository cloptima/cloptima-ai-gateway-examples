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
| `npm run agentic-runaway` | Retry and loop-iteration limits derived from conversation tool-call transcripts, blocking runaway loops. |
| `npm run pii-guardrail` | A profile custom rule blocks a fictional SSN format before model egress. |
| `npm run exact-semantic-cache` | Exact-cache (enforce) and semantic-cache (observe) evidence. |
| `npm run conversation-prompt-caching` | Provider-side prompt caching on a growing multi-turn conversation with long system context. |
| `npm run provider-deny` | A non-Vertex model request blocked by a Vertex-only policy. |
| `npm run metadata-deny` | A deliberately unscoped key with no attribution headers, blocked. |
| `npm run byok` | Bring your own provider credential and route it through Cloptima's governance layer (needs `PROVIDER_API_KEY` in `.env`). |
| `npm run unit-economics-roi` | A cost-center agent (ROI vs. a pre-LLM baseline) and a profit-center agent (real booked revenue) side by side, each with its own computed report. |
| `npm run contract-pricing` | Seed a negotiated-rate price sheet and commitment, then read back retail vs. contracted vs. effective cost on customer-owned credentials (needs `PROVIDER_API_KEY` in `.env`). |
| `npm run semantic-cache-enforce` | Semantic-cache enforce mode: the per-(app, route, model) class approval it needs, plus immediate enforcement and the applied governance-queue record. |
| `npm run approval-workflow` | Request a manual budget-change approval, show one request pending, then apply a second request immediately through the generic governance queue. |
| `npm run guardrail-detector-categories` | Creates isolated policy-bound profiles and exercises Google Model Armor, Azure AI Content Safety, and Amazon Bedrock Guardrails (requires available managed credits). |
| `npm run guardrail-cost-governance` | Sets a per-request scan cost cap in a provider-backed guardrail profile (requires available managed credits). |
| `npm run adaptive-routing` | Adaptive routing in observe mode across cheap/balanced/strong candidate model tiers. |
| `npm run prompt-release-workflow` | Prompt template, version, automated eval, quality gating, and release approval - demonstrating failed-gate block and successful activation via applyImmediately. |
| `npm run mcp-tool-governance` | MCP server registration, approval rules, tool-definition review, and blocked server/tool checks. |
| `npm run session-trace-audit` | Tool I/O capture under `promptRetentionMode: 'tool_io'` with multi-turn session correlation, immediate ledger cryptographic hashes (`traceSha256`), and audit verification. |
| `npm run cleanup` | Reset the account: delete all policies, bindings, guardrail profiles, tool servers, datasets, and ROI calibrations; archive prompt templates and price sheets; revoke keys and credentials; reject pending approvals. |

Each script prints illustrative policy limits it's using and says plainly that they're a starting point, not a fixed platform requirement - change the constant at the top of any script and re-run it.

## Resetting Resources & Account Quotas

Each example script provisions its own policy, virtual key, and binding on the fly. Running multiple scripts will consume quotas on your account (such as maximum policies or active keys). If you hit account limit errors during an evaluation tour, or want to clean up afterward, run:

```bash
npm run cleanup
```

In automated or CI environments, pass `--force` to bypass the interactive confirmation:

```bash
npm run cleanup -- --force
```

> [!WARNING]
> **Account-Wide Cleanup**: This script permanently deletes **all** AI gateway policies, policy bindings, guardrail profiles, registered MCP tool servers, eval datasets, and ROI calibrations; archives **all** prompt templates and price sheets; revokes **all** active virtual keys and provider credentials; and rejects **all** pending approval requests in the current account. Run only in sandbox or test accounts, never against production environments.

## How the gateway calls work

- The gateway URL is already built into `src/lib/config.mjs` - you don't need to know or set it.
- OpenAI-style client points at `<gateway>/v1/ai` (the SDK appends `/chat/completions`).
- Anthropic-style client points at the gateway root (the SDK appends `/v1/messages`).
- Both send the virtual key as their normal API key - no custom auth code needed.
- Supported managed-gateway attribution rides as `x-cloptima-*` request headers; telemetry-only dimensions are listed separately in `../docs/ENVIRONMENT.md`.
- There is no client-side cache toggle - exact/semantic caching is entirely policy-driven server-side (see `../docs/CACHE_AND_POLICY.md`).
- Policy/key/binding creation goes through the public `createLLMGatewayPolicy` / `createLLMGatewayKey` / `createLLMGatewayPolicyBinding` GraphQL mutations - see `src/lib/gatewayAdmin.mjs`.

## How each script is laid out

Every example follows the same three steps, so you can read any of them top to bottom:

1. **Cloptima setup** - create the policy, virtual key, and binding. Together these are the entire contract; nothing later asks the gateway to enforce anything.
2. **Your application code** - the official `openai` or `@anthropic-ai/sdk` client, called exactly as you would call it without Cloptima.
3. **What the gateway did** - print the outcome, then confirm it against what the policy in step 1 configured (`src/lib/confirm.mjs`).

That last step is a real check, not narration: if a limit, guardrail, or scope did not hold, the script exits non-zero with a message naming the control that failed, so a run can never report a governance guarantee it did not get.
