// Thin wrapper that normalizes success/blocked/error outcomes across the
// OpenAI-style and Anthropic-style SDKs so scenarios.mjs doesn't repeat try/catch.
//
// A policy block from the gateway arrives as a non-2xx response, which both
// SDKs raise as an APIError with .status and a parsed .error body.
// Policy/provider/model blocks come back as 403 with {error, reason,
// violations}; missing-attribution on a fully unscoped key comes back as 400
// with a plain {error} string instead (an earlier, more basic gate than the
// policy engine) - this prints whatever the gateway returns rather than
// assuming one shape, so both cases render correctly.
export async function callOpenAIStyle(client, { model, prompt, headers, label }) {
  try {
    const response = await client.chat.completions.create(
      { model, messages: [{ role: 'user', content: prompt }] },
      { headers },
    );
    return {
      label,
      outcome: 'allowed',
      requestId: response.id,
      usage: response.usage,
      text: response.choices?.[0]?.message?.content,
    };
  } catch (err) {
    return errorOutcome(label, err);
  }
}

export async function callAnthropicStyle(client, { model, prompt, headers, label }) {
  try {
    const response = await client.messages.create(
      { model, max_tokens: 300, messages: [{ role: 'user', content: prompt }] },
      { headers },
    );
    return {
      label,
      outcome: 'allowed',
      requestId: response.id,
      usage: response.usage,
      text: response.content?.[0]?.text,
    };
  } catch (err) {
    return errorOutcome(label, err);
  }
}

function errorOutcome(label, err) {
  const status = err?.status ?? err?.response?.status;
  const body = err?.error ?? err?.response?.data ?? err?.message;
  const outcome = status && status >= 400 && status < 500 ? 'blocked' : 'error';
  return { label, outcome, status, reason: body };
}
