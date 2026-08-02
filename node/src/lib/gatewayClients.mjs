import OpenAI from 'openai';
import Anthropic from '@anthropic-ai/sdk';

// OpenAI-compatible clients point at <base>/v1/ai and the SDK appends
// /chat/completions, /embeddings, etc. The SDK sends Authorization: Bearer <key>.
export function openaiStyleClient(virtualKey, baseUrl) {
  return new OpenAI({ apiKey: virtualKey, baseURL: `${baseUrl}/v1/ai` });
}

// Anthropic-compatible clients point at the gateway root and the SDK appends
// /v1/messages. The SDK sends x-api-key: <key>, which the gateway accepts
// specifically for Anthropic-SDK compatibility on /v1/ai and /v1/messages paths.
export function anthropicStyleClient(virtualKey, baseUrl) {
  return new Anthropic({ apiKey: virtualKey, baseURL: baseUrl });
}
