# Cloptima AI gateway examples (Python)

Each script in `examples/` is independent and self-contained: it creates its own policy, virtual key, and binding using the official `openai` and `anthropic` packages - no Cloptima-specific SDK required for inference - then runs its scenario and prints what happened. Run any single one in isolation; none of them depend on another having run first.

## Setup

Requires **Python 3.9+** and pip:

```bash
python3 --version # verify Python 3.9+ is active
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in CLOPTIMA_AI_ADMIN_KEY
```

Short on time? See [`../README.md`](../README.md#suggested-tour-10-minutes) for a suggested 7-script run order.

## Examples

Run any of these from the `python/` directory:

| Command | What it shows |
| --- | --- |
| `python -m examples.quickstart_openai` | Simplest working call, using the OpenAI SDK. |
| `python -m examples.quickstart_anthropic` | Same, using the Anthropic SDK's own calling convention. |
| `python -m examples.multi_model` | One policy allowlisting several Vertex AI Gemini model variants, called through it to compare cost and latency. |
| `python -m examples.rate_limit` | A realistic per-minute request cap tripping after several calls. |
| `python -m examples.token_limit` | A realistic output-token cap blocking a too-long request pre-flight. |
| `python -m examples.budget_limit` | A small daily spend cap admitting several calls, then denying the rest. |
| `python -m examples.agentic_runaway` | Retry/loop-iteration limits catching a simulated runaway agent loop. |
| `python -m examples.pii_guardrail` | A model generates fake PII live, then a guardrail-enforced key blocks it. |
| `python -m examples.exact_semantic_cache` | Exact-cache (enforce) and semantic-cache (observe) evidence. |
| `python -m examples.provider_deny` | A non-Vertex model request blocked by a Vertex-only policy. |
| `python -m examples.metadata_deny` | A deliberately unscoped key with no attribution headers, blocked. |
| `python -m examples.byok` | Bring your own provider credential and route it through Cloptima's governance layer (needs `PROVIDER_API_KEY` in `.env`). |
| `python -m examples.unit_economics_roi` | A cost-center agent (ROI vs. a pre-LLM baseline) and a profit-center agent (real booked revenue) side by side, each with its own computed report. |
| `python -m examples.contract_pricing` | Seed a negotiated-rate price sheet and commitment, then read back retail vs. contracted vs. effective cost. |

Each script prints illustrative policy limits it's using and says plainly that they're a starting point, not a fixed platform requirement - change the constant near the top of any script and re-run it.

## How the gateway calls work

- The gateway URL is already built into `lib/config.py` - you don't need to know or set it.
- OpenAI-style client points at `<gateway>/v1/ai` (the SDK appends `/chat/completions`).
- Anthropic-style client points at the gateway root (the SDK appends `/v1/messages`).
- Both send the virtual key as their normal API key - no custom auth code needed.
- Attribution and agent-context metadata ride as `x-cloptima-*` request headers via `extra_headers` (see `lib/attribution.py` and `../docs/ENVIRONMENT.md`).
- There is no client-side cache toggle - exact/semantic caching is entirely policy-driven server-side (see `../docs/CACHE_AND_POLICY.md`).
- Policy/key/binding creation goes through the public `createLLMGatewayPolicy` / `createLLMGatewayKey` / `createLLMGatewayPolicyBinding` GraphQL mutations - see `lib/gateway_admin.py`.
