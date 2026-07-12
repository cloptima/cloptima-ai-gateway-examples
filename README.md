# Cloptima AI Gateway Examples

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/cloptima/cloptima-ai-gateway-examples)

Self-contained examples for integrating with Cloptima's managed AI gateway: virtual keys, attribution, policy enforcement, rate/token/budget limits, agentic-runaway limits, PII/secret guardrails, caching, unit economics/ROI, bring-your-own-key (BYOK), and multi-model policies via Vertex AI (several Gemini variants under one policy).

Don't want to run anything locally? See [`docs/RUNNING_SAFELY.md`](docs/RUNNING_SAFELY.md) for every way to run these - your own agent's sandbox, a Docker container, GitHub Codespaces, or the console with no code at all.

These examples are all built against the `vertex_ai` provider - every model shown here is called through Vertex AI, using Cloptima's own canonical model IDs (e.g. `vertex_ai/gemini-2.5-flash`).

Every example is independent - it creates whatever policy, virtual key, and binding it needs, runs its own scenario, and prints what happened. Pick any single one and run it in isolation; nothing here depends on a prior step having run.

## Start here

You need one thing: an `ai:admin` management key. That key can create everything else itself (policies, bindings, virtual keys, provider credentials) - nothing is pre-provisioned for you, and the gateway URL is already built into the example code, so you don't need to know or configure it.

If you don't have a key, you can generate one in the Cloptima Console under Settings > API Keys.

## Suggested tour (~10 minutes)

Short on time? Run these seven in order - each one builds on the last to cover the full story: governed access, multi-model policies, live enforcement, guardrails, cache efficiency, business ROI, and BYOK trust. Everything else in the example table below is supplementary depth (alternate limit types, scoping edge cases) - explore it afterward, in any order.

1. `quickstart-openai` (or `quickstart-anthropic`) - simplest governed call; proves the gateway works.
2. `multi-model` - one policy, several Gemini model variants - the multi-model cost/latency story.
3. `budget-limit` - a real spend cap admitting several calls, then denying the rest - live enforcement, not a toy first-call failure.
4. `pii-guardrail` - a model generates fake PII live, then a guardrail blocks it - proves detection, not a hardcoded fixture match.
5. `exact-semantic-cache` - cache savings and cache-hit evidence - the cost-efficiency story.
6. `unit-economics-roi` - a cost-center agent (support automation, ROI vs. a pre-LLM baseline) and a profit-center agent (checkout upsell, real booked revenue) side by side - the business-value story, both directions.
7. `byok` - route your own provider key through Cloptima's governance layer - the trust signal.

The rest (`rate-limit`, `token-limit`, `agentic-runaway`, `provider-deny`, `metadata-deny`) prove the same enforcement story with different limit types and scoping edge cases - worth running, just not essential to a first pass.

## Pick a stack

Verify you have the required versions installed for your preferred local development environment:

- **Node.js**: Requires Node.js 18+ (needed for native `fetch` support) and npm.
- **Python**: Requires Python 3.9+ and `venv` (standard library).
- **Shell**: Requires Bash/Zsh, `curl`, and `jq` (used to parse JSON).

| Directory | Stack | Environment Requirements |
| --- | --- | --- |
| [`node/`](node/) | Official `openai` + `@anthropic-ai/sdk` npm packages | Node.js 18+ & npm |
| [`python/`](python/) | Official `openai` + `anthropic` pypi packages | Python 3.9+ & pip |
| [`shell/`](shell/) | `curl` + `jq` only - zero package installs | Bash/Zsh, `curl`, `jq` |

Each directory has the same set of independent example scripts:

| Example | What it shows |
| --- | --- |
| `quickstart-openai` | Simplest working call, OpenAI-compatible shape. |
| `quickstart-anthropic` | Simplest working call, Anthropic-compatible shape. |
| `multi-model` | One policy allowlisting several Vertex AI Gemini model variants, called through it to compare cost and latency. |
| `rate-limit` | A realistic per-minute request cap tripping after several calls. |
| `token-limit` | A realistic output-token cap blocking a too-long request pre-flight. |
| `budget-limit` | A small daily spend cap admitting several calls, then denying the rest. |
| `agentic-runaway` | Retry/loop-iteration limits catching a simulated runaway agent loop. |
| `pii-guardrail` | A model generates fake PII live, then a guardrail-enforced key blocks it - not a hardcoded test string. |
| `exact-semantic-cache` | Exact-cache (enforce) and semantic-cache (observe) evidence. |
| `provider-deny` | A non-Vertex model request blocked by a Vertex-only policy. |
| `metadata-deny` | A deliberately unscoped key with no attribution headers, blocked. |
| `byok` | Bring your own provider credential and route it through Cloptima's governance layer. |
| `unit-economics-roi` | A cost-center agent (ROI vs. a pre-LLM baseline) and a profit-center agent (real booked revenue) side by side, each with its own computed report. |
| `contract-pricing` | Seed a negotiated-rate price sheet and commitment, then read back retail vs. contracted vs. effective cost. |

See each directory's own README for exact run commands. Every illustrative policy limit (rate, token, budget, loop-iteration caps) is a realistic starting point printed by the script itself, not a fixed platform requirement - change the constant near the top of any script and re-run it to see the behavior move.

Already running your own agent framework (LangChain, LlamaIndex, CrewAI, the OpenAI Agents SDK, Vercel AI SDK)? See [`docs/FRAMEWORK_QUICKSTART.md`](docs/FRAMEWORK_QUICKSTART.md) - you can likely point it at the gateway directly without touching any example script.

## Reference docs

- [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md) - every env var and every `x-cloptima-*` attribution header, what it does.
- [`docs/CACHE_AND_POLICY.md`](docs/CACHE_AND_POLICY.md) - why there's no client-side cache toggle, and how attribution headers indirectly affect cache scope.
- [`docs/CONSOLE_GUIDE.md`](docs/CONSOLE_GUIDE.md) - how to log in and a tab-by-tab map of the console, cross-referenced to which example populates which tab.
- [`docs/RUNNING_SAFELY.md`](docs/RUNNING_SAFELY.md) - every way to run these examples (your agent's own sandbox, Docker, Codespaces, or console-only), with exact commands and what each does/doesn't require.

## Console tabs

Every script prints an `Evidence:` line pointing at one of these. `/` and `/llm/*` are the canonical, public console routes:

| Tab | URL | What it shows |
| --- | --- | --- |
| Dashboard | `https://app.cloptima.ai` | Realized cache savings, blended effective cost (retail vs. contracted), and other org-wide FinOps rollups. |
| Explorer | `https://app.cloptima.ai/llm/spend` | Per-request attributed spend, usage, latency, and cached-token counts. |
| Economics | `https://app.cloptima.ai/llm/unit-economics` | Cost-per-unit, margin, and net-ROI computed from unit-metrics + ROI calibration. |
| Recommendations | `https://app.cloptima.ai/llm/recommendations` | Cost-optimization suggestions (model right-sizing, caching, guardrail tuning) computed from real usage history over time - not produced by any single example run. |
| Policies | `https://app.cloptima.ai/llm/policies` | The policy configs (limits, guardrails, cache modes) each example creates. |
| Credentials | `https://app.cloptima.ai/llm/credentials` | Virtual keys and BYOK provider credentials. |
| Audit | `https://app.cloptima.ai/llm/audit` | Blocked-request records - policy/provider/model/token/guardrail/agentic-limit blocks. |

## How the gateway works, in short

- The gateway URL is hardcoded in each language's `config` module - nobody running these examples needs to know or set it.
- OpenAI-compatible clients: base URL `<gateway>/v1/ai`, key sent as `Authorization: Bearer <virtual key>`.
- Anthropic-compatible clients: base URL `<gateway>` root, key sent as `x-api-key: <virtual key>`.
- Models are addressed by Cloptima canonical ID, e.g. `vertex_ai/gemini-2.5-flash`.
- Policies, bindings, and virtual keys are created via the public `createLLMGatewayPolicy` / `createLLMGatewayPolicyBinding` / `createLLMGatewayKey` GraphQL mutations, using your `ai:admin` key - see any example's `lib`/`gatewayAdmin` helper for the exact calls.
- Attribution, agent-session/run/tool context, and ROI business-transaction metadata all ride as `x-cloptima-*` request headers - no special SDK required.
- Policy enforcement (allowed providers/models, rate/token/budget limits, agentic-runaway limits, required metadata) happens server-side based on which virtual key you used. Most blocks come back as `403` with `{error, reason, violations}`; a rate-limit block is `429`; a fully unscoped key with no attribution at all comes back as a plain `400` instead - see `docs/ENVIRONMENT.md`.
- Unit economics (cost per unit, margin, ROI) are computed from real gateway/telemetry traffic plus a unit-metrics batch you submit yourself - see `unit-economics-roi`.
- Enterprise contract pricing (negotiated rates, commitments) is modeled as a price sheet with rate overrides, applied to real cost calculations once approved - see `contract-pricing`.
- If you write your own raw HTTP call against the gateway (rather than using the `openai`/`anthropic` SDKs, which already send their own identifying User-Agent), send a real `User-Agent` header. The gateway sits behind Cloudflare, and requests with no or generic UAs (a bare `curl`/`python-requests`/unset-fetch signature) can get bot-blocked before they ever reach the application. Every raw HTTP call in this repo already does this - see `USER_AGENT`/`config.USER_AGENT` in each language's `config` module.

If something doesn't match what you see, the console's Audit/Explorer views are the source of truth, not this repo.
