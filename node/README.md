# Cloptima AI Gateway Examples (Node.js)

Examples of how to connect an application to the Cloptima AI Gateway with the official `openai` and `@anthropic-ai/sdk` packages, and how your code behaves when a governance control applies. No Cloptima-specific inference SDK is needed.

## Integrating in two lines

To send traffic through Cloptima, change the API key and the base URL. Everything else is your existing SDK code.

### OpenAI SDK

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  apiKey: process.env.CLOPTIMA_VIRTUAL_KEY,
  baseURL: 'https://api.cloptima.ai/v1/ai', // the SDK appends /chat/completions
});

const response = await client.chat.completions.create({
  model: 'vertex_ai/gemini-3.5-flash-lite',
  messages: [{ role: 'user', content: 'Hello Cloptima!' }],
});
```

### Anthropic SDK

```javascript
import Anthropic from '@anthropic-ai/sdk';

const client = new Anthropic({
  apiKey: process.env.CLOPTIMA_VIRTUAL_KEY,
  baseURL: 'https://api.cloptima.ai', // the SDK appends /v1/messages
});

const response = await client.messages.create({
  model: 'vertex_ai/gemini-3.5-flash-lite',
  max_tokens: 1024,
  messages: [{ role: 'user', content: 'Hello Cloptima!' }],
});
```

## How each example is organized

Every file in `src/examples/` has two parts:

1. **Governance setup.** The policy (and any guardrail profile, tool server, or price sheet) the scenario runs under, written inline with its real configuration. Platform teams normally create these once in the Console, Terraform, or CI.
2. **Application code.** What your service does: make calls, handle blocks, and read results. This is the part to copy into your own code.

## Run an example

Requires Node.js 18+ and npm.

```bash
npm install
cp .env.example .env
npm run quickstart-openai
```

Set one credential in `.env`:

- `CLOPTIMA_AI_ADMIN_KEY`: the example runs its governance setup for you, then runs the application code. Works with every example.
- `CLOPTIMA_VIRTUAL_KEY`: the example skips setup and runs only the application code with your key. Use it with the examples marked **Virtual key** below. The key must be bound to a policy like the one in the file's governance setup, or the scenario will not trigger.

Some examples need more: `byok` and `contract-pricing` need `PROVIDER_API_KEY` (or `CLOPTIMA_PROVIDER_CREDENTIAL_ID`), and the managed guardrail examples need available managed credits.

## Handling gateway responses

When a control applies, the gateway returns a standard HTTP error that the SDK raises as an API error:

```json
{
  "error": "Request blocked by policy",
  "reason": "guardrail_violation",
  "violations": ["us_ssn"]
}
```

The standard OpenAI SDK only exposes the `error` string on raised API errors, dropping `reason` and `violations`. To make `err.error.reason` and `err.error.violations` available in catch blocks, initialize the client using the helper in `src/lib/client.mjs` (or pass a custom `fetch` wrapper):

```javascript
import { openaiClient } from './lib/client.mjs';

const client = openaiClient(process.env.CLOPTIMA_VIRTUAL_KEY);

try {
  await client.chat.completions.create({ ... });
} catch (err) {
  if (err.status === 403) {
    console.log('Reason:', err.error?.reason);
    console.log('Violations:', err.error?.violations);
  }
}
```

| Status | Typical cause | What your application does |
| --- | --- | --- |
| **402** | Budget limit exhausted (`gateway_daily_budget_exceeded` or spend limit). | Stop non-critical requests or alert FinOps. |
| **403** | A guardrail, provider or model allowlist, tool allowlist, or loop cap blocked the request. `err.error.violations` lists the reasons. | Show a safe message to the user, fall back to an approved model, or stop the agent. |
| **429** | Request rate limit exceeded. | Back off and retry with exponential backoff. |
| **400** | Required attribution (team, app) is missing, or a request parameter is invalid. | Add the attribution headers or correct the request. |

## Examples

| Command | Auth | Scenario |
| --- | --- | --- |
| `npm run quickstart-openai` | Virtual key | Chat completion and streaming with the OpenAI SDK. |
| `npm run quickstart-anthropic` | Virtual key | Messages and streaming with the Anthropic SDK. |
| `npm run multi-model` | Virtual key | Compare latency and token cost across models under one policy. |
| `npm run pii-guardrail` | Virtual key | Support bot blocks an SSN before it reaches the model and returns a friendly fallback. |
| `npm run provider-deny` | Virtual key | Compliance policy blocks a non-approved provider; the app falls back to an approved model. |
| `npm run rate-limit` | Virtual key | Batch worker retries with exponential backoff on HTTP 429. |
| `npm run token-limit` | Virtual key | Summarization service handles an output-token cap. |
| `npm run budget-limit` | Virtual key | Job stops non-critical work when the daily budget is reached. |
| `npm run agentic-runaway` | Virtual key | Agent loop is stopped by the policy's loop-iteration cap. |
| `npm run exact-semantic-cache` | Virtual key | Latency and token savings from exact and semantic cache hits. |
| `npm run conversation-prompt-caching` | Virtual key | Provider prompt caching on a growing multi-turn conversation (OpenAI and Anthropic). |
| `npm run adaptive-routing` | Virtual key | Adaptive routing in observe mode across cheap, balanced, and strong model tiers. |
| `npm run guardrail-cost-governance` | Virtual key | Per-request cost cap on a managed guardrail scan. |
| `npm run metadata-deny` | Virtual key | Requests without team and app attribution are refused; attributed requests are admitted. With `CLOPTIMA_VIRTUAL_KEY`, use an unscoped key (no team or app baked in) bound to a policy that requires attribution. |
| `npm run guardrail-detector-categories` | Virtual key | One managed guardrail scan per run: Google Model Armor (default), Azure AI Content Safety, or Amazon Bedrock Guardrails. Choose with `GUARDRAIL_PROVIDER=google-model-armor\|azure-content-safety\|bedrock-guardrails`. |
| `npm run byok` | Virtual key + `CLOPTIMA_PROVIDER_CREDENTIAL_ID`, or admin key + `PROVIDER_API_KEY` | Route calls through your own provider credential. |
| `npm run semantic-cache-enforce` | Admin key | Enforce-mode semantic cache, including the class approval it needs. |
| `npm run unit-economics-roi` | Admin key | Cost-center and profit-center ROI from business-outcome headers and unit metrics. |
| `npm run contract-pricing` | Admin key + `PROVIDER_API_KEY` or `CLOPTIMA_PROVIDER_CREDENTIAL_ID` | Negotiated rate sheet versus retail cost on your own credentials. |
| `npm run approval-workflow` | Admin key | Budget-change request waits in the governance queue; a pre-authorized change applies immediately. |
| `npm run prompt-release-workflow` | Admin key | Prompt evaluation against a golden dataset and a quality-gated release. |
| `npm run mcp-tool-governance` | Admin key | Tool servers start disabled until reviewed; unregistered servers and disallowed tools are blocked. |
| `npm run session-trace-audit` | Admin key | Agent session with tool I/O capture and per-step integrity hashes (`traceSha256`). |
| `npm run cleanup` | Admin key | Delete the policies, keys, profiles, and datasets the examples created. |

## Cleanup

Each run creates a policy, a virtual key, and a binding. To remove what the examples created:

```bash
npm run cleanup             # asks for confirmation
npm run cleanup -- --force  # no prompt
```
