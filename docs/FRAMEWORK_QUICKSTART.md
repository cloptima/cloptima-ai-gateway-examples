# Framework quickstart

If your agent already runs on one of these frameworks, you likely don't need the example apps at all - just point the framework's OpenAI/Anthropic client at the Cloptima gateway with a virtual key. All of these frameworks are OpenAI-SDK-compatible under the hood, so the same base URL / auth rules from `../docs/ENVIRONMENT.md` apply: base URL `https://api.cloptima.ai/v1/ai`, API key = your virtual key.

Package/API names below shift between versions - treat these as a starting point, not copy-paste guarantees, and check your installed version's docs if a constructor argument doesn't match.

## LangChain (Python)

```python
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(
    model="vertex_ai/gemini-2.5-flash",
    base_url="https://api.cloptima.ai/v1/ai",
    api_key="clop_vk_...",
    default_headers={
        "x-cloptima-team": "Platform AI",
        "x-cloptima-app": "eval-runner",
        "x-cloptima-environment": "dev",
    },
)
```

## LangChain (JS/TS)

```ts
import { ChatOpenAI } from "@langchain/openai";

const llm = new ChatOpenAI({
  model: "vertex_ai/gemini-2.5-flash",
  apiKey: "clop_vk_...",
  configuration: {
    baseURL: "https://api.cloptima.ai/v1/ai",
    defaultHeaders: {
      "x-cloptima-team": "Platform AI",
      "x-cloptima-app": "eval-runner",
      "x-cloptima-environment": "dev",
    },
  },
});
```

## LlamaIndex (Python)

```python
from llama_index.llms.openai import OpenAI

llm = OpenAI(
    model="vertex_ai/gemini-2.5-flash",
    api_base="https://api.cloptima.ai/v1/ai",
    api_key="clop_vk_...",
)
```

## CrewAI

CrewAI agents accept an `llm` argument, so wire the same LangChain `ChatOpenAI` client shown above and hand it to the agent instead of a model string:

```python
from crewai import Agent
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(
    model="vertex_ai/gemini-2.5-flash",
    base_url="https://api.cloptima.ai/v1/ai",
    api_key="clop_vk_...",
)

agent = Agent(role="...", goal="...", backstory="...", llm=llm)
```

## OpenAI Agents SDK (Python, `openai-agents`)

```python
from openai import AsyncOpenAI
from agents import Agent, Runner, set_default_openai_client

client = AsyncOpenAI(
    base_url="https://api.cloptima.ai/v1/ai",
    api_key="clop_vk_...",
    default_headers={"x-cloptima-team": "Platform AI", "x-cloptima-app": "eval-runner"},
)
set_default_openai_client(client)

agent = Agent(name="demo-agent", model="vertex_ai/gemini-2.5-flash", instructions="...")
Runner.run_sync(agent, "...")
```

## Vercel AI SDK (JS/TS)

```ts
import { createOpenAI } from "@ai-sdk/openai";
import { generateText } from "ai";

const cloptima = createOpenAI({
  baseURL: "https://api.cloptima.ai/v1/ai",
  apiKey: "clop_vk_...",
  headers: {
    "x-cloptima-team": "Platform AI",
    "x-cloptima-app": "eval-runner",
    "x-cloptima-environment": "dev",
  },
});

const { text } = await generateText({
  model: cloptima("vertex_ai/gemini-2.5-flash"),
  prompt: "...",
});
```

## What you lose by skipping the example scripts

The `provider-deny` and `metadata-deny` examples in `../node`, `../python`, and `../shell` deliberately create policies that exercise a blocked path, and `unit-economics-roi` shows the unit-metrics submission. Wiring a framework directly (as above) gets you governed, attributed inference immediately, but you won't see enforcement or unit economics unless you also create a policy with real limits, send business-transaction headers yourself, and submit unit-metrics using your `ai:admin` key (see `../python/examples/unit_economics_roi.py` or `../node/src/examples/unit-economics-roi.mjs` for the exact call).
