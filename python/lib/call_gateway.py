"""Thin wrapper that normalizes success/blocked/error outcomes across the
OpenAI-style and Anthropic-style SDKs so scenarios.py doesn't repeat try/except.

A policy block from the gateway arrives as a non-2xx response, which both
SDKs raise as an APIStatusError with .status_code and a parsed .body.
Policy/provider/model blocks come back as 403 with {error, reason, violations};
missing-attribution on a fully unscoped key comes back as 400 with a plain
{error} string instead (an earlier, more basic gate than the policy engine) -
this prints whatever the gateway returns rather than assuming one shape, so
both cases render correctly.
"""

from anthropic import APIStatusError as AnthropicAPIStatusError
from openai import APIStatusError as OpenAIAPIStatusError


def call_openai_style(client, model, prompt, headers, label):
    try:
        response = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            extra_headers=headers,
        )
        return {
            "label": label,
            "outcome": "allowed",
            "request_id": response.id,
            "usage": response.usage.model_dump() if response.usage else None,
            "text": response.choices[0].message.content if response.choices else None,
        }
    except OpenAIAPIStatusError as err:
        return _error_outcome(label, err)


def call_anthropic_style(client, model, prompt, headers, label):
    try:
        response = client.messages.create(
            model=model,
            max_tokens=300,
            messages=[{"role": "user", "content": prompt}],
            extra_headers=headers,
        )
        return {
            "label": label,
            "outcome": "allowed",
            "request_id": response.id,
            "usage": response.usage.model_dump() if response.usage else None,
            "text": response.content[0].text if response.content else None,
        }
    except AnthropicAPIStatusError as err:
        return _error_outcome(label, err)


def _error_outcome(label, err):
    status = getattr(err, "status_code", None)
    body = getattr(err, "body", None) or str(err)
    outcome = "blocked" if status and 400 <= status < 500 else "error"
    return {"label": label, "outcome": outcome, "status": status, "reason": body}
