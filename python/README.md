# Cloptima AI gateway examples (Python)

Examples showing how to integrate Python applications with Cloptima's managed AI gateway using the official `openai` and `anthropic` SDKs, and how your code behaves when governance controls apply.

## Integrating in two lines

Swap your provider API key for a Cloptima virtual key and point the base URL at the gateway:

### OpenAI SDK

```python
import os
from openai import OpenAI

client = OpenAI(
    api_key=os.environ["CLOPTIMA_VIRTUAL_KEY"],
    base_url="https://api.cloptima.ai/v1/ai",  # the SDK appends /chat/completions
)

response = client.chat.completions.create(
    model="vertex_ai/gemini-3.5-flash-lite",
    messages=[{"role": "user", "content": "Hello Cloptima!"}],
)
```

### Anthropic SDK

```python
import os
from anthropic import Anthropic

client = Anthropic(
    api_key=os.environ["CLOPTIMA_VIRTUAL_KEY"],
    base_url="https://api.cloptima.ai",  # the SDK appends /v1/messages
)

response = client.messages.create(
    model="vertex_ai/gemini-3.5-flash-lite",
    max_tokens=1024,
    messages=[{"role": "user", "content": "Hello Cloptima!"}],
)
```

## How each example is organized

Every file in `examples/` has two parts:

1. **Governance setup.** The policy (and any guardrail profile, tool server, or price sheet) the scenario runs under, written inline with its real configuration. Platform teams normally create these once in the Console, Terraform, or CI.
2. **Application code.** What your service does: make calls, handle blocks, and read results. This is the part to copy into your own code.

## Run an example

Requires Python 3.9+ and pip.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python -m examples.quickstart_openai
```

Set one credential in `.env`:

- `CLOPTIMA_AI_ADMIN_KEY`: the example runs its governance setup for you, then runs the application code. Works with every example.
- `CLOPTIMA_VIRTUAL_KEY`: the example skips setup and runs only the application code with your key. Use it with the examples marked **Virtual key** below. The key must be bound to a policy like the one in the file's governance setup, or the scenario will not trigger.

Some examples need more: `byok` and `contract_pricing` need `PROVIDER_API_KEY` (or `CLOPTIMA_PROVIDER_CREDENTIAL_ID`), and the managed guardrail examples need available managed credits.

## Handling gateway responses

When a control applies, the gateway returns a standard HTTP error that the SDK raises as an API error:

```json
{
  "error": "Request blocked by policy",
  "reason": "guardrail_violation",
  "violations": ["us_ssn"]
}
```

The standard OpenAI Python SDK parses error responses into `err.body`, but drops `reason` and `violations` by default if not nested. To make `reason` and `violations` available in `except APIStatusError` blocks, initialize the client using the helper in `lib/client.py` (which attaches a transparent `httpx` transport):

```python
from openai import APIStatusError
from lib.client import openai_client

client = openai_client(os.environ["CLOPTIMA_VIRTUAL_KEY"])

try:
    client.chat.completions.create(...)
except APIStatusError as err:
    if err.status_code == 403:
        body = err.body if isinstance(err.body, dict) else {}
        print("Reason:", body.get("reason"))
        print("Violations:", body.get("violations"))
```

| Status | Typical cause | What your application does |
| --- | --- | --- |
| **402** | Budget limit exhausted (`gateway_daily_budget_exceeded` or spend limit). | Stop non-critical requests or alert FinOps. |
| **403** | A guardrail, provider or model allowlist, tool allowlist, or loop cap blocked the request. `violations` lists the reasons. | Show a safe message to the user, fall back to an approved model, or stop the agent. |
| **429** | Request rate limit exceeded. | Back off and retry with exponential backoff. |
| **400** | Required attribution (team, app) is missing, or a request parameter is invalid. | Add the attribution headers or correct the request. |

## Examples

| Command | Auth | Scenario |
| --- | --- | --- |
| `python -m examples.quickstart_openai` | Virtual key | Chat completion and streaming with the OpenAI SDK. |
| `python -m examples.quickstart_anthropic` | Virtual key | Messages and streaming with the Anthropic SDK. |
| `python -m examples.multi_model` | Virtual key | Compare latency and token cost across models under one policy. |
| `python -m examples.pii_guardrail` | Virtual key | Support bot blocks an SSN before it reaches the model and returns a friendly fallback. |
| `python -m examples.provider_deny` | Virtual key | Compliance policy blocks a non-approved provider; the app falls back to an approved model. |
| `python -m examples.rate_limit` | Virtual key | Batch worker retries with exponential backoff on HTTP 429. |
| `python -m examples.token_limit` | Virtual key | Summarization service handles an output-token cap. |
| `python -m examples.budget_limit` | Virtual key | Job stops non-critical work when the daily budget is reached. |
| `python -m examples.agentic_runaway` | Virtual key | Agent loop is stopped by the policy's loop-iteration and tool-retry caps. |
| `python -m examples.exact_semantic_cache` | Virtual key | Latency and token savings from exact and semantic cache hits. |
| `python -m examples.conversation_prompt_caching` | Virtual key | Provider prompt caching on a growing multi-turn conversation (OpenAI and Anthropic). |
| `python -m examples.adaptive_routing` | Virtual key | Adaptive routing in observe mode across cheap, balanced, and strong model tiers. |
| `python -m examples.guardrail_cost_governance` | Virtual key | Per-request cost cap on a managed guardrail scan. |
| `python -m examples.metadata_deny` | Virtual key | Requests without team and app attribution are refused; attributed requests are admitted. With `CLOPTIMA_VIRTUAL_KEY`, use an unscoped key (no team or app baked in) bound to a policy that requires attribution. |
| `python -m examples.guardrail_detector_categories` | Virtual key | One managed guardrail scan per run: Google Model Armor (default), Azure AI Content Safety, or Amazon Bedrock Guardrails. Choose with `GUARDRAIL_PROVIDER=google-model-armor\|azure-content-safety\|bedrock-guardrails`. |
| `python -m examples.byok` | Virtual key + `CLOPTIMA_PROVIDER_CREDENTIAL_ID`, or admin key + `PROVIDER_API_KEY` | Route calls through your own provider credential. |
| `python -m examples.semantic_cache_enforce` | Admin key | Enforce-mode semantic cache, including the class approval it needs. |
| `python -m examples.unit_economics_roi` | Admin key | Cost-center and profit-center ROI from business-outcome headers and unit metrics. |
| `python -m examples.contract_pricing` | Admin key + `PROVIDER_API_KEY` or `CLOPTIMA_PROVIDER_CREDENTIAL_ID` | Negotiated rate sheet versus retail cost on your own credentials. |
| `python -m examples.approval_workflow` | Admin key | Budget-change request waits in the governance queue; a pre-authorized change applies immediately. |
| `python -m examples.prompt_release_workflow` | Admin key | Prompt evaluation against a golden dataset and a quality-gated release. |
| `python -m examples.mcp_tool_governance` | Admin key | Tool servers start disabled until reviewed; unregistered servers and disallowed tools are blocked. |
| `python -m examples.session_trace_audit` | Admin key | Agent session with tool I/O capture and per-step integrity hashes (`traceSha256`). |
| `python -m examples.cleanup` | Admin key | Delete the policies, keys, profiles, and datasets the examples created. |

## Cleanup

Each run creates a policy, a virtual key, and a binding. To remove what the examples created:

```bash
python -m examples.cleanup             # asks for confirmation
python -m examples.cleanup --force     # no prompt
```
