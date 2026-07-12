# Cloptima AI gateway examples (shell / curl)

Each script here is independent and self-contained: `curl` + `jq` only, no other dependency. It creates its own policy, virtual key, and binding, runs its scenario, and prints what happened. Run any single one in isolation; none of them depend on another having run first. `lib.sh` holds the small set of shared helpers (`graphql`, `create_policy`, `create_virtual_key`, `create_binding`, `call_chat`, `call_messages`) every script sources.

## Requirements

- `curl`
- `jq`
- `uuidgen` (falls back to `python3 -c 'import uuid...'` if not present)

## Setup

```bash
cp .env.example .env   # fill in CLOPTIMA_AI_ADMIN_KEY
```

Short on time? See [`../README.md`](../README.md#suggested-tour-10-minutes) for a suggested 7-script run order.

## Examples

| Script | What it shows |
| --- | --- |
| `./quickstart-openai.sh` | Simplest working call, OpenAI-compatible shape. |
| `./quickstart-anthropic.sh` | Same, Anthropic-compatible shape. |
| `./multi-model.sh` | One policy allowlisting several Vertex AI Gemini model variants, called through it to compare cost and latency. |
| `./rate-limit.sh` | A realistic per-minute request cap tripping after several calls. |
| `./token-limit.sh` | A realistic output-token cap blocking a too-long request pre-flight. |
| `./budget-limit.sh` | A small daily spend cap admitting several calls, then denying the rest. |
| `./agentic-runaway.sh` | Retry/loop-iteration limits catching a simulated runaway agent loop. |
| `./pii-guardrail.sh` | A model generates fake PII live, then a guardrail-enforced key blocks it. |
| `./exact-semantic-cache.sh` | Exact-cache (enforce) and semantic-cache (observe) evidence. |
| `./provider-deny.sh` | A non-Vertex model request blocked by a Vertex-only policy. |
| `./metadata-deny.sh` | A deliberately unscoped key with no attribution headers, blocked. |
| `./byok.sh` | Bring your own provider credential and route it through Cloptima's governance layer (needs `PROVIDER_API_KEY` in `.env`). |
| `./unit-economics-roi.sh` | A cost-center agent (ROI vs. a pre-LLM baseline) and a profit-center agent (real booked revenue) side by side, each with its own computed report. |
| `./contract-pricing.sh` | Seed a negotiated-rate price sheet and commitment, then read back retail vs. contracted vs. effective cost. |

Each script prints illustrative policy limits it's using and says plainly that they're a starting point, not a fixed platform requirement - edit the constants near the top of any script and re-run it.

`rate-limit.sh` in particular is timing-sensitive: the cap is enforced per fixed clock-minute, and `curl`'s per-call subprocess overhead means a run can occasionally straddle a minute boundary and get a fresh quota partway through, letting more than the cap's worth of calls through across the two windows. If a run doesn't trip the cap, just re-run it - it reliably trips when the calls land within a single clock-minute.

## How the gateway calls work

- The gateway URL is already built into `lib.sh` - you don't need to know or set it.
- OpenAI-style: `POST <gateway>/v1/ai/chat/completions` with `Authorization: Bearer <virtual key>`.
- Anthropic-style: `POST <gateway>/v1/messages` with `x-api-key: <virtual key>` and `anthropic-version: 2023-06-01`.
- Attribution/agent-context metadata rides as `x-cloptima-*` headers (see `../docs/ENVIRONMENT.md`).
- There is no client-side cache toggle - caching is entirely policy-driven server-side (see `../docs/CACHE_AND_POLICY.md`).
- Policy/key/binding creation goes through the public `createLLMGatewayPolicy` / `createLLMGatewayKey` / `createLLMGatewayPolicyBinding` GraphQL mutations - see `lib.sh`.
