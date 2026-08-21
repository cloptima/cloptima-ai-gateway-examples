# Environment variables and attribution headers

## Env vars

Every example in this repo needs just one thing:

| Variable | Notes |
| --- | --- |
| `CLOPTIMA_AI_ADMIN_KEY` | Management key (`ai:admin` + `ai:write` + `ai:read`). Creates/tests provider credentials, policies, bindings, and inference virtual keys, and reads back reports. Cannot invoke inference itself - each example mints its own inference-scoped (`ai:invoke`) virtual key from this and uses that for actual model calls. |

One more, only for the BYOK example:

| Variable | Notes |
| --- | --- |
| `PROVIDER_API_KEY` | Your own provider API key (e.g. OpenAI) - this is what BYOK brings onto the platform. |

Do not use the `ai:admin` key where an inference virtual key is expected, or vice versa - the gateway enforces this at the scope level, not just as a convention.

The gateway URL itself is not something you set - it's hardcoded to the production endpoint in each language's `config` module (`CLOPTIMA_GATEWAY_BASE_URL` is read as an optional override only, unset by default).

### A note on User-Agent

The gateway sits behind Cloudflare, which bot-manages requests carrying no or generic User-Agent strings - a bare `curl`, unconfigured Node `fetch`, or default `python-requests` signature can get blocked at the network edge before the request ever reaches the application. The official `openai`/`anthropic` SDKs already send their own identifying UA, so this only matters for this repo's own raw HTTP calls (GraphQL policy/key/binding creation, and the few examples - `budget-limit`, `byok`, `unit-economics-roi` - that call the inference/ingest endpoints directly instead of through an SDK client). Every raw call in this repo already sets a `Cloptima-AI-Gateway-Examples/1.0` User-Agent - see `USER_AGENT`/`config.USER_AGENT` in each language's `config` module. If you write your own raw HTTP call against the gateway, do the same.

## Managed-gateway request headers

These headers are supported on managed inference calls (`/v1/ai/...`, `/v1/messages`). Both the OpenAI and Anthropic SDKs accept them through their per-call `headers`/`extra_headers` option; no Cloptima-specific inference SDK is required.

| Header | Purpose |
| --- | --- |
| `x-cloptima-team` | Team attribution for an otherwise unscoped key. |
| `x-cloptima-app` | Application attribution for an otherwise unscoped key. |
| `x-cloptima-environment` | Environment attribution (`dev`, `prod`, etc.). |
| `x-cloptima-feature` | Feature-area label for reporting. |
| `x-cloptima-workflow` | Workflow ID, e.g. `model_eval`. |
| `x-cloptima-workflow-step` | Step within a workflow. |
| `x-cloptima-developer-id` | Developer or automation identity used for reporting. |
| `x-cloptima-agent-session-id` | Stable agent-session identity used for agent-aware governance and audit. |
| `x-cloptima-business-transaction-id` | Correlates the request with a business transaction. |
| `x-cloptima-business-transaction-type` | Workload or transaction category, e.g. `support_ticket_resolved`. |
| `x-cloptima-business-transaction-unit-count` | Number of business units represented by the request. |
| `x-cloptima-business-outcome-status` | Business outcome label such as `resolved` or `accepted`. |
| `x-cloptima-business-outcome-success` | Boolean success indicator used by unit-economics reporting. |
| `x-cloptima-business-value-cents` | Business value attributed to the request, in cents. |

A virtual key's configured team, app, and environment remain available when a request sends no attribution headers. This is why the `metadata-deny` example uses a deliberately unscoped key. Policy selection remains tied to the virtual key and its configured bindings; request headers do not select a different policy. Client-supplied tenant identity is not accepted.

Only documented Cloptima headers are interpreted. Arbitrary `x-cloptima-*` headers are not custom attribution fields and are not stored.

## Direct telemetry attribution headers

Direct telemetry ingestion supports additional reporting and correlation dimensions. Use these with a supported telemetry integration when the application needs richer FinOps breakdowns; they are not managed-gateway inference headers and do not control which policy handles a request.

| Header | Purpose |
| --- | --- |
| `x-cloptima-actor-id` / `x-cloptima-actor-type` | Human, service, or agent caller attribution. |
| `x-cloptima-release` | Release or deployment version. |
| `x-cloptima-business-unit` / `x-cloptima-cost-center` / `x-cloptima-product` | Finance-facing allocation dimensions. |
| `x-cloptima-customer-segment` / `x-cloptima-end-customer-id` / `x-cloptima-tenant-id` | Downstream customer and multi-tenant reporting. |
| `x-cloptima-agent-run-id` / `x-cloptima-parent-execution-id` | Agent execution-chain correlation. |
| `x-cloptima-tool-name` / `x-cloptima-tool-call-id` | Tool-call attribution in agent telemetry. |
| `x-cloptima-trace-id` / `x-cloptima-request-id` | Cross-system telemetry correlation. |

The managed gateway derives run, parent, tool-call, loop, and retry context from actual request execution where applicable. Applications should not send manual loop or retry override headers.

## What you cannot set from a request

There is no client-side header or body flag for exact-cache or semantic-cache behavior - see `CACHE_AND_POLICY.md`. There is also no way to override which policy applies to a call from the request; policy binding is resolved server-side from the virtual key's principal, not from headers.

## Two different shapes for a blocked call

A blocked call doesn't always look the same:

- **Policy/provider/model/token/agentic-limit blocks**: `403` with a JSON body `{error, reason, violations, ...}` (some also include a `details` object, e.g. the token-limit block names both the requested and allowed values).
- **Rate limit specifically**: `429`, not `403`.
- **Missing attribution on a fully unscoped key with no headers at all**: a more fundamental `400` with a plain `{error}` string ("Managed AI requests require Cloptima team and app attribution") - this fires before the request ever reaches policy evaluation, so it doesn't carry `reason`/`violations` fields the way policy-engine blocks do.

Write error handling against status code plus a generic "read whatever `error`/`reason` fields exist" pattern (see `callGateway.mjs`/`call_gateway.py`) rather than assuming one fixed shape.
