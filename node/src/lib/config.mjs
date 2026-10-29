import 'dotenv/config';

// The gateway is a fixed public endpoint - nobody running these examples
// should need to know or configure its URL. CLOPTIMA_GATEWAY_BASE_URL is an
// optional override only, unset by default.
const GATEWAY_BASE_URL_DEFAULT = 'https://api.cloptima.ai';

export const config = {
  baseUrl: (process.env.CLOPTIMA_GATEWAY_BASE_URL || GATEWAY_BASE_URL_DEFAULT).replace(/\/+$/, ''),
  aiAdminKey: process.env.CLOPTIMA_AI_ADMIN_KEY || '',
  virtualKey: process.env.CLOPTIMA_VIRTUAL_KEY || '',
};

// The gateway sits behind Cloudflare, which bot-manages requests with no or
// generic User-Agent strings (Node's fetch sends none by default, and
// SDK-bypassing raw fetch calls in a couple of examples would otherwise look
// like anonymous scripted traffic). The official openai/anthropic SDKs
// already send their own identifying UA, so this only needs to be applied to
// this repo's own raw fetch calls (see gatewayAdmin.mjs and any example that
// calls fetch() directly instead of going through an SDK client).
export const USER_AGENT = 'Cloptima-AI-Gateway-Examples/1.0';

// Console tab URLs each example points to as corroborating evidence.
// These are the canonical, public paths to view results in the console.
const CONSOLE_ROOT = 'https://app.cloptima.ai/llm';
export const CONSOLE = {
  dashboard: 'https://app.cloptima.ai',
  spend: `${CONSOLE_ROOT}/spend`,
  unitEconomics: `${CONSOLE_ROOT}/unit-economics`,
  policies: `${CONSOLE_ROOT}/policies`,
  guardrails: `${CONSOLE_ROOT}/guardrails`,
  credentials: `${CONSOLE_ROOT}/credentials`,
  audit: `${CONSOLE_ROOT}/audit`,
  sessions: `${CONSOLE_ROOT}/sessions`,
};

// A short, unique-ish suffix so re-running an example doesn't collide with a
// policy/app name it created on a previous run (policy names are unique per
// customer).
export function runSuffix() {
  return Math.random().toString(36).slice(2, 8);
}
