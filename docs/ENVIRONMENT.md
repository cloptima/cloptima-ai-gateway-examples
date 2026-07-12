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

The gateway URL itself is not something you set - it's hardcoded to the production endpoint in each language's `config` module (`CLOPTIMA_GATEWAY_BASE_URL` is read as an optional override only, unset by default, for internal testing against a non-production environment).

### A note on User-Agent

The gateway sits behind Cloudflare, which bot-manages requests carrying no or generic User-Agent strings - a bare `curl`, unconfigured Node `fetch`, or default `python-requests` signature can get blocked at the network edge before the request ever reaches the application. The official `openai`/`anthropic` SDKs already send their own identifying UA, so this only matters for this repo's own raw HTTP calls (GraphQL policy/key/binding creation, and the few examples - `budget-limit`, `byok`, `unit-economics-roi` - that call the inference/ingest endpoints directly instead of through an SDK client). Every raw call in this repo already sets a `Cloptima-AI-Gateway-Examples/1.0` User-Agent - see `USER_AGENT`/`config.USER_AGENT` in each language's `config` module. If you write your own raw HTTP call against the gateway, do the same.

## Attribution / agent-context request headers

These ride as plain HTTP headers on every managed-gateway inference call (`/v1/ai/...`, `/v1/messages`). Both the OpenAI and Anthropic SDKs (Node and Python) accept a per-call `headers`/`extra_headers` option - no special client is required.

| Header | Purpose |
| --- | --- |
| `x-cloptima-team` | Team attribution. |
| `x-cloptima-app` | App attribution. |
| `x-cloptima-environment` | Environment attribution (`dev`, `prod`, etc.). |
| `x-cloptima-feature` | Feature-area label for reporting. |
| `x-cloptima-workflow` | Workflow ID, e.g. `model_eval`. |
| `x-cloptima-workflow-step` | Step within a workflow. |
| `x-cloptima-business-unit` / `x-cloptima-cost-center` / `x-cloptima-product` | Finance-facing dimensions. |
| `x-cloptima-customer-segment` / `x-cloptima-end-customer-id` / `x-cloptima-tenant-id` | Multi-tenant / end-customer attribution, for anyone building a product on top of Cloptima-governed access. |
| `x-cloptima-release` | Release/version label. |
| `x-cloptima-business-transaction-id` / `-type` / `-unit-count` / `-outcome-status` / `-value-cents` | ROI inputs - tie a call to a real business outcome (e.g. `support_ticket_resolved`) so `net_roi_usd` and related fields can be calculated against an ROI calibration row you create (see `unit-economics-roi`). |
| `x-cloptima-agent-session-id` / `x-cloptima-agent-run-id` | Agent-aware governance - groups calls into a session/run for audit. |
| `x-cloptima-parent-execution-id` | Links a sub-call back to a parent agent execution. |
| `x-cloptima-tool-name` / `x-cloptima-tool-call-id` | Identifies which tool/sub-step within an agent run a call belongs to. |
| `x-cloptima-loop-iteration` / `x-cloptima-retry-index` | Which iteration of a simulated agent loop/retry a call represents - what the `agentic-runaway` example increments to trip `maxLoopIterations`/`maxRetryCount`. |
| `x-cloptima-actor-id` / `x-cloptima-actor-type` / `x-cloptima-developer-id` | Who or what triggered the call. |
| `x-cloptima-trace-id` / `x-cloptima-request-id` | Correlation IDs for cross-system tracing. |

Headers are authoritative; a `metadata` object in the request body is a fallback used only when the corresponding header is absent, and a virtual key's own team/app/environment (set when the key was created) is a further fallback below that. This last point matters: a key created with `teamId`/`appId`/`environment` set will resolve those values even if a given call sends no headers at all - which is why the `metadata-deny` example needs a *deliberately unscoped* key to demonstrate a real block, rather than just omitting headers on an already-scoped key. Client-supplied `customer_id` is never trusted from the body - your tenant boundary is always resolved from the key itself.

## What you cannot set from a request

There is no client-side header or body flag for exact-cache or semantic-cache behavior - see `CACHE_AND_POLICY.md`. There is also no way to override which policy applies to a call from the request; policy binding is resolved server-side from the virtual key's principal, not from headers.

## Two different shapes for a blocked call

A blocked call doesn't always look the same:

- **Policy/provider/model/token/agentic-limit blocks**: `403` with a JSON body `{error, reason, violations, ...}` (some also include a `details` object, e.g. the token-limit block names both the requested and allowed values).
- **Rate limit specifically**: `429`, not `403`.
- **Missing attribution on a fully unscoped key with no headers at all**: a more fundamental `400` with a plain `{error}` string ("Managed AI requests require Cloptima team and app attribution") - this fires before the request ever reaches policy evaluation, so it doesn't carry `reason`/`violations` fields the way policy-engine blocks do.

Write error handling against status code plus a generic "read whatever `error`/`reason` fields exist" pattern (see `callGateway.mjs`/`call_gateway.py`) rather than assuming one fixed shape.
