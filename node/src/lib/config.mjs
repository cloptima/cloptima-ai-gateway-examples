import 'dotenv/config';

function required(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var ${name} - copy .env.example to .env and fill it in.`);
  }
  return value;
}

// The gateway is a fixed public endpoint - nobody running these examples
// should need to know or configure its URL. Only override it (unset by
// default) for internal testing against a non-production environment.
const GATEWAY_BASE_URL_DEFAULT = 'https://api.cloptima.ai';

// Every example in this repo needs only one thing: an ai:admin management
// key. Each example mints whatever policy, binding, and virtual key it needs
// from there - nothing is pre-provisioned.
export const config = {
  baseUrl: (process.env.CLOPTIMA_GATEWAY_BASE_URL || GATEWAY_BASE_URL_DEFAULT).replace(/\/+$/, ''),
  aiAdminKey: required('CLOPTIMA_AI_ADMIN_KEY'),
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
  recommendations: `${CONSOLE_ROOT}/recommendations`,
  policies: `${CONSOLE_ROOT}/policies`,
  credentials: `${CONSOLE_ROOT}/credentials`,
  audit: `${CONSOLE_ROOT}/audit`,
};

// A short, unique-ish suffix so re-running an example doesn't collide with a
// policy/app name it created on a previous run (policy names are unique per
// customer).
export function runSuffix() {
  return Math.random().toString(36).slice(2, 8);
}
