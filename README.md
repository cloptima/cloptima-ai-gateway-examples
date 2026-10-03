# Cloptima AI Gateway Examples

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/cloptima/cloptima-ai-gateway-examples)

Examples of how to integrate an application with Cloptima's managed AI gateway using the official `openai` and `anthropic` SDKs, and how your code behaves when a governance control applies: virtual keys, attribution, policy enforcement, rate/token/budget limits, agentic-runaway limits, PII/secret guardrails, caching, unit economics/ROI, bring-your-own-key (BYOK), and multi-model policies.

Don't want to run anything locally? See [`docs/RUNNING_SAFELY.md`](docs/RUNNING_SAFELY.md) for every way to run these - your own agent's sandbox, a Docker container, GitHub Codespaces, or the console with no code at all.

## Enterprise Platform Capabilities

While this repository focuses on client-side developer integration examples and proxy behaviors, the Cloptima platform natively supports production-grade enterprise requirements for AI governance and managed gateways:

* **Hybrid & VPC Edge Deployment**: Deploy the Cloptima Edge Gateway directly within your own VPC or on-premises environment to keep inference traffic inside your security boundary.
* **Offline Resilience & Local Enforcement**: The edge runtime syncs signed policy snapshots to a high-performance local store to evaluate budgets, rate limits, and security guardrails with sub-millisecond overhead, continuing to enforce policies offline even during cloud disconnections.
* **High Availability & Failover**: Multi-instance edge deployments support robust high-availability configurations to ensure continuous service, sub-minute failovers, and high-throughput reliability.
* **Unified Multi-Provider Catalog**: Supports token attribution, proxying, and policy enforcement across all major LLM providers (including Vertex AI, OpenAI, Anthropic, and custom engines) via standard SDKs, with support for routing Bring-Your-Own-Key (BYOK) credentials.
* **Enterprise SSO & SCIM Sync**: Governs team budgets, policies, and virtual keys dynamically by integrating with identity providers like Microsoft Entra and Google Workspace via OIDC SSO and automated SCIM directory synchronization.
* **KMS Secrets Management**: Protects and rotates provider credentials and API keys using cloud-native Key Management Services (KMS) with enterprise-grade encryption.

---

These examples are all built against the `vertex_ai` provider - every model shown here is called through Vertex AI, using Cloptima's own canonical model IDs (e.g. `vertex_ai/gemini-3.5-flash-lite`).

Every example is independent - it creates whatever policy, virtual key, and binding it needs, runs its own scenario, and prints what happened. Pick any single one and run it in isolation; nothing here depends on a prior step having run.

## Start here

Integrating an application takes two changes to your existing SDK setup: use a Cloptima virtual key as the API key, and point the base URL at the gateway. The [Node README](node/README.md#integrating-in-two-lines) shows both snippets.

Each example then adds one governance control and shows the application code that works with it. Every example is split into a **Governance setup** block (the policy, guardrail profile, or tool server the scenario runs under) and the **application code** you would copy into your own service.

Credentials:

- **Node, Python, and shell**: set `CLOPTIMA_VIRTUAL_KEY` to run only the application code against a key you already have, or set `CLOPTIMA_AI_ADMIN_KEY` and the example creates its own policy, key, and binding. Examples that configure governance resources (approvals, MCP tool servers, prompts, price sheets, ROI, session audit) need the admin key.

Generate either key in the Cloptima Console under Settings > API Keys. The two managed-provider guardrail examples also need an available Cloptima managed-credit balance, because their Google Model Armor, Azure AI Content Safety, and Amazon Bedrock Guardrails scans are billable.

## Suggested path

1. **Connect**: `quickstart-openai` or `quickstart-anthropic`.
2. **Protect**: `pii-guardrail`, `provider-deny`, `mcp-tool-governance`.
3. **Control cost and load**: `budget-limit`, `rate-limit`, `token-limit`, `agentic-runaway`, `metadata-deny`.
4. **Optimize**: `multi-model`, `adaptive-routing`, `exact-semantic-cache`, `conversation-prompt-caching`.
5. **Govern changes**: `approval-workflow`, `semantic-cache-enforce`, `prompt-release-workflow`.
6. **Prove value**: `unit-economics-roi`, `contract-pricing`, `session-trace-audit`, `byok`.

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
| `agentic-runaway` | Retry and loop-iteration limits derived from conversation tool-call transcripts, blocking runaway loops. |
| `pii-guardrail` | A profile custom rule blocks a fictional SSN format before model egress. |
| `exact-semantic-cache` | Exact-cache (enforce) and semantic-cache (observe) evidence. |
| `conversation-prompt-caching` | Provider-side prompt caching on a growing multi-turn conversation with long system context. |
| `provider-deny` | A non-Vertex model request blocked by a Vertex-only policy. |
| `metadata-deny` | A deliberately unscoped key with no attribution headers, blocked. |
| `byok` | Bring your own provider credential and route it through Cloptima's governance layer. |
| `unit-economics-roi` | A cost-center agent (ROI vs. a pre-LLM baseline) and a profit-center agent (real booked revenue) side by side, each with its own computed report. |
| `contract-pricing` | Seed a negotiated-rate price sheet and commitment, then read back retail vs. contracted vs. effective cost on customer-owned credentials (needs `PROVIDER_API_KEY` in `.env`). |
| `semantic-cache-enforce` | Semantic-cache enforce mode: the per-(app, route, model) class approval it needs, plus immediate enforcement and the applied governance-queue record. |
| `approval-workflow` | Request a manual budget-change approval, show one request pending, then apply a second request immediately through the generic governance queue. |
| `guardrail-detector-categories` | Creates isolated policy-bound profiles and exercises Google Model Armor, Azure AI Content Safety, and Amazon Bedrock Guardrails (requires available managed credits). |
| `guardrail-cost-governance` | Sets a per-request scan cost cap in a provider-backed guardrail profile (requires available managed credits). |
| `adaptive-routing` | Adaptive routing in observe mode across cheap/balanced/strong candidate model tiers. |
| `prompt-release-workflow` | Prompt template, version, automated eval, quality gating, and release approval - demonstrating failed-gate block and successful activation via applyImmediately. |
| `mcp-tool-governance` | MCP server registration, approval rules, tool-definition review, and blocked server/tool checks. |
| `session-trace-audit` | Tool I/O capture under `promptRetentionMode: 'tool_io'` with multi-turn session correlation, immediate ledger cryptographic hashes (`traceSha256`), and audit verification. |
| `cleanup` | Reset the account: delete all policies, bindings, guardrail profiles, tool servers, datasets, and ROI calibrations; archive prompt templates and price sheets; revoke keys and credentials; reject pending approvals. |

See each directory's own README for exact run commands. Every illustrative policy limit (rate, token, budget, loop-iteration caps) is a realistic starting point printed by the script itself, not a fixed platform requirement - change the constant near the top of any script and re-run it to see the behavior move. Note: Rate limits are enforced per calendar minute window (e.g., 10:00:00-10:00:59 UTC), not a rolling 60-second window.

## Account Resource Quotas and Cleanup

Each example dynamically provisions its own policy, virtual key, and binding. When you run many examples or run them repeatedly, these resources accumulate in the account. Depending on your organization's subscription tier entitlements, you may encounter an error if you exceed account-level resource limits (such as the maximum allowed policies or active virtual keys).

Each language directory includes a `cleanup` utility to reset your account's gateway resources:

- **Node**: `npm run cleanup` (or `npm run cleanup -- --force` for non-interactive execution)
- **Python**: `python -m examples.cleanup` (or `python -m examples.cleanup --force`)
- **Shell**: `./cleanup.sh` (or `./cleanup.sh --force`)

You can run this cleanup script to start from a clean state, or after you finish.

> [!WARNING]
> **Account-Wide Deletion Warning**: The cleanup script permanently deletes **all** AI gateway policies, policy bindings, guardrail profiles, registered MCP tool servers, eval datasets, and ROI calibrations; archives **all** prompt templates and price sheets; revokes **all** active virtual keys and provider credentials; and rejects **all** pending approval requests in the authenticated account.
>
> Only run cleanup in dedicated sandbox, evaluation, or demo accounts. **Never** run this script in an account containing production traffic, live API keys, or persistent business policies.

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
- Models are addressed by Cloptima canonical ID, e.g. `vertex_ai/gemini-3.5-flash-lite`.
- Policies, bindings, and virtual keys are created via the public `createLLMGatewayPolicy` / `createLLMGatewayPolicyBinding` / `createLLMGatewayKey` GraphQL mutations, using your `ai:admin` key - see any example's `lib`/`gatewayAdmin` helper for the exact calls.
- Managed-gateway attribution, agent-session identity, and ROI business-transaction context can ride as documented `x-cloptima-*` request headers with no special inference SDK. Additional actor, release, finance, tenant, run, tool, and trace dimensions belong to direct telemetry integrations; see `docs/ENVIRONMENT.md` for the capability matrix.
- Policy enforcement (allowed providers/models, rate/token/budget limits, agentic-runaway limits, required metadata) happens server-side based on which virtual key you used. Most blocks come back as `403` with `{error, reason, violations}`; a rate-limit block is `429`; a fully unscoped key with no attribution at all comes back as a plain `400` instead - see `docs/ENVIRONMENT.md`.
- Unit economics (cost per unit, margin, ROI) are computed from real gateway/telemetry traffic plus a unit-metrics batch you submit yourself - see `unit-economics-roi`.
- Enterprise contract pricing (negotiated rates, commitments) is modeled as a price sheet with rate overrides governing customer-owned provider accounts and credentials (BYOK). Negotiated rate sheets apply to customer-owned keys, while the managed-credits wallet evaluates at standard catalog pricing - see `contract-pricing`.
- If you write your own raw HTTP call against the gateway (rather than using the `openai`/`anthropic` SDKs, which already send their own identifying User-Agent), send a real `User-Agent` header. The gateway sits behind Cloudflare, and requests with no or generic UAs (a bare `curl`/`python-requests`/unset-fetch signature) can get bot-blocked before they ever reach the application. Every raw HTTP call in this repo already does this - see `USER_AGENT`/`config.USER_AGENT` in each language's `config` module.

If something doesn't match what you see, the console's Audit/Explorer views are the source of truth, not this repo.
