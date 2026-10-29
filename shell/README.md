# Cloptima AI Gateway Examples (shell / curl)

Examples of how to call the Cloptima AI Gateway with plain `curl` and `jq`, and how your scripts and services behave when a governance control applies. No SDK and no package install.

## Integrating in two lines

To send traffic through Cloptima, use a Cloptima virtual key as the credential and the gateway as the URL. The request body is the standard OpenAI or Anthropic shape.

### OpenAI-compatible

```bash
curl -sS https://api.cloptima.ai/v1/ai/chat/completions \
  -H "Authorization: Bearer $CLOPTIMA_VIRTUAL_KEY" \
  -H "Content-Type: application/json" \
  -H "User-Agent: my-app/1.0" \
  -d '{
    "model": "vertex_ai/gemini-3.5-flash-lite",
    "messages": [{"role": "user", "content": "Hello Cloptima!"}]
  }'
```

### Anthropic-compatible

```bash
curl -sS https://api.cloptima.ai/v1/messages \
  -H "x-api-key: $CLOPTIMA_VIRTUAL_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -H "User-Agent: my-app/1.0" \
  -d '{
    "model": "vertex_ai/gemini-3.5-flash-lite",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": "Hello Cloptima!"}]
  }'
```

Always send a `User-Agent` header. The gateway sits behind a bot-managed edge that can block requests with none or a generic one.

## How each example is organized

Every script has two parts:

1. **Governance setup.** The policy (and any guardrail profile, tool server, or price sheet) the scenario runs under, written inline with its real configuration. Platform teams normally create these once in the Console, Terraform, or CI.
2. **Application code.** What your service does: `curl` calls, handling blocks, and reading results. This is the part to copy into your own scripts.

`lib.sh` holds the small set of helpers the setup uses (`get_access`, `provision_app`, `admin_api` for the Cloptima REST API, and the `create_*` helpers) and `describe_block`, which prints the message, reason, and violations from a blocked response.

## Run an example

Requires `curl` and `jq`.

```bash
cp .env.example .env
./quickstart-openai.sh
```

Set one credential in `.env`:

- `CLOPTIMA_AI_ADMIN_KEY`: the script runs its governance setup for you, then runs the application code. Works with every example.
- `CLOPTIMA_VIRTUAL_KEY`: the script skips setup and runs only the application code with your key. Use it with the examples marked **Virtual key** below. The key must be bound to a policy like the one in the script's governance setup, or the scenario will not trigger.

Some examples need more: `byok` and `contract-pricing` need `PROVIDER_API_KEY` (or `CLOPTIMA_PROVIDER_CREDENTIAL_ID`). `pii-guardrail` and `content-safety-guardrail` need the `llm_guardrail_enterprise` entitlement. Every other model call runs on Cloptima-managed credentials and needs available AI credits; Cloptima-managed content-safety scans are billed to the same credits.

## Handling gateway responses

When a control applies, the gateway returns a non-2xx status and a JSON body:

```json
{ "error": "<message>", "reason": "<reason code>", "violations": ["<violation>"] }
```

Check the status with `curl -w '%{http_code}'` and read the body with `jq`.

| Status | Typical cause | What your application does |
| --- | --- | --- |
| **402** | Budget limit exhausted. | Stop non-critical requests or alert FinOps. |
| **403** | A guardrail, provider or model allowlist, tool allowlist, or loop cap blocked the request. `violations` lists the reasons. | Show a safe message to the user, fall back to an approved model, or stop the agent. |
| **429** | Request rate limit exceeded. | Back off and retry with exponential backoff. |
| **400** | Required attribution (team, app) is missing, or a request parameter is invalid. | Add the attribution headers or correct the request. |

## Examples

| Script | Auth | Scenario |
| --- | --- | --- |
| `./quickstart-openai.sh` | Virtual key | Chat completion and streaming in the OpenAI-compatible shape. |
| `./quickstart-anthropic.sh` | Virtual key | Messages and streaming in the Anthropic-compatible shape. |
| `./multi-model.sh` | Virtual key | Compare latency and token cost across models under one policy. |
| `./pii-guardrail.sh` | Virtual key | Support bot: email addresses and phone numbers are redacted before the model provider sees them and restored in the response; a message with an employee ID is blocked and the app returns a friendly fallback. |
| `./content-safety-guardrail.sh` | Virtual key | Cloptima-managed content safety answers a normal request and blocks a prompt-injection attempt. |
| `./provider-deny.sh` | Virtual key | Compliance policy blocks a non-approved provider; the app falls back to an approved model. |
| `./rate-limit.sh` | Virtual key | Batch worker retries with exponential backoff on HTTP 429. |
| `./token-limit.sh` | Virtual key | Summarization service handles an output-token cap. |
| `./budget-limit.sh` | Virtual key | Job stops non-critical work when the daily budget is reached. |
| `./agentic-runaway.sh` | Virtual key | Agent loop and repeated tool retries are stopped by the policy's loop and retry caps. |
| `./exact-semantic-cache.sh` | Virtual key | Latency and token savings from exact and semantic cache hits. |
| `./conversation-prompt-caching.sh` | Virtual key | Provider prompt caching on a growing multi-turn conversation (OpenAI and Anthropic). |
| `./metadata-deny.sh` | Virtual key | Requests without team and app attribution are refused; attributed requests are admitted. With `CLOPTIMA_VIRTUAL_KEY`, use an unscoped key (no team or app baked in) bound to a policy that requires attribution. |
| `./byok.sh` | Virtual key + `CLOPTIMA_PROVIDER_CREDENTIAL_ID`, or admin key + `PROVIDER_API_KEY` | Route calls through your own provider credential. |
| `./semantic-cache-enforce.sh` | Admin key | Enforce-mode semantic cache, including the class approval it needs. |
| `./unit-economics-roi.sh` | Admin key | Cost-center and profit-center ROI from business-outcome headers and unit metrics. |
| `./contract-pricing.sh` | Admin key + `PROVIDER_API_KEY` or `CLOPTIMA_PROVIDER_CREDENTIAL_ID` | Negotiated rate sheet versus retail cost on your own credentials. |
| `./approval-workflow.sh` | Admin key | Budget-change request waits in the governance queue; a pre-authorized change applies immediately. |
| `./mcp-tool-governance.sh` | Admin key | Tool servers start disabled until reviewed; unregistered servers and disallowed tools are blocked. |
| `./session-trace-audit.sh` | Admin key | Agent session with tool I/O capture and per-step integrity hashes (`trace_sha256`). |
| `./cleanup.sh` | Admin key | Delete the policies, bindings, keys, profiles, tool servers, and other gateway resources in the account. Use it only in a sandbox account. |

## Cleanup

Each run creates a policy, a virtual key, and a binding. To remove what the examples created:

```bash
./cleanup.sh          # asks for confirmation
./cleanup.sh --force  # no prompt
```
