import OpenAI from 'openai';
import Anthropic from '@anthropic-ai/sdk';
import { config } from './config.mjs';

// The gateway reports a blocked request as
//   { error: "<message>", reason: "...", violations: ["..."], details: {...} }
// The OpenAI SDK only exposes the `error` field on a raised API error, which would
// drop `reason` and `violations`. This fetch wrapper nests the whole body under
// `error`, so `err.error.message`, `err.error.reason` and `err.error.violations`
// are available in a catch block.
async function gatewayFetch(input, init) {
  const response = await fetch(input, init);
  if (response.ok) return response;

  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return new Response(text, { status: response.status, statusText: response.statusText, headers: response.headers });
  }
  if (typeof body?.error === 'string') {
    const { error, ...rest } = body;
    body = { error: { message: error, ...rest } };
  }
  const headers = new Headers(response.headers);
  headers.delete('content-length');
  headers.delete('content-encoding');
  return new Response(JSON.stringify(body), { status: response.status, statusText: response.statusText, headers });
}

// OpenAI SDK client pointed at the Cloptima gateway. The only changes from a
// direct-to-provider setup are the API key (a Cloptima virtual key) and the base URL.
export function openaiClient(virtualKey, options = {}) {
  return new OpenAI({ apiKey: virtualKey, baseURL: `${config.baseUrl}/v1/ai`, fetch: gatewayFetch, ...options });
}

// Anthropic SDK client pointed at the Cloptima gateway.
export function anthropicClient(virtualKey, options = {}) {
  return new Anthropic({ apiKey: virtualKey, baseURL: config.baseUrl, ...options });
}
