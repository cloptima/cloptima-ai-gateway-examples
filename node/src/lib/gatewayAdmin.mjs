import { config, USER_AGENT } from './config.mjs';

// Thin REST helper used by every example to create its own policy, binding,
// and virtual key with the shared ai:admin key. Nothing here is
// Cloptima-internal - these are the same public REST endpoints any customer's
// own tooling would call. Request bodies and response fields use the API's
// snake_case field names.
//
// `query` values that are undefined are skipped; an array value is sent as
// repeated keys (unit_type=a&unit_type=b). Every POST carries a JSON body
// (`{}` when the operation takes none): the API requires a JSON content type
// on every POST. A 204 answer returns undefined. Any other non-2xx answer
// throws an Error whose `status` is the HTTP status and whose message carries
// the API error `{ error: { code, message } }`.
export async function adminApi(method, path, { query, body = method === 'POST' ? {} : undefined } = {}) {
  if (!config.aiAdminKey) {
    throw new Error('This example creates governance resources and needs CLOPTIMA_AI_ADMIN_KEY. Add it to .env (see .env.example).');
  }
  const url = new URL(`${config.baseUrl}${path}`);
  for (const [key, value] of Object.entries(query ?? {})) {
    if (value === undefined || value === null) continue;
    for (const item of [value].flat()) url.searchParams.append(key, String(item));
  }
  const headers = { 'user-agent': USER_AGENT, authorization: `Bearer ${config.aiAdminKey}` };
  if (body !== undefined) headers['content-type'] = 'application/json';

  const response = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (response.status === 204) return undefined;
  const text = await response.text();
  if (!response.ok) {
    let detail = text;
    try {
      const { error } = JSON.parse(text);
      if (error?.code || error?.message) detail = `${error.code}: ${error.message}`;
    } catch {
      // Not JSON: report the raw text.
    }
    throw Object.assign(new Error(`${method} ${path} failed (HTTP ${response.status}): ${detail}`), { status: response.status });
  }
  return text ? JSON.parse(text) : undefined;
}

export function createPolicy(policy) {
  return adminApi('POST', '/v1/llm/policies', { body: policy });
}

export function createGuardrailProfile(profile) {
  return adminApi('POST', '/v1/llm/guardrail-profiles', { body: profile });
}

// The response's `access_token` is the virtual key the application uses.
export function createVirtualKey(key) {
  return adminApi('POST', '/v1/llm/gateway-keys', { body: key });
}

export function createBinding(binding) {
  return adminApi('POST', '/v1/llm/policy-bindings', { body: binding });
}

// Generic governance queue - any policy, budget, or tool-server change that
// needs sign-off before it takes effect goes through this same queue, not a
// scenario-specific approval queue.
export function createApproval(approval) {
  return adminApi('POST', '/v1/llm/approvals', { body: approval });
}

// Returns { items, next_cursor }. Query: status, search, limit, cursor.
export function listApprovals(query) {
  return adminApi('GET', '/v1/llm/approvals', { query });
}

// Returns { agent_session_id, items, next_cursor }: one item per request in the
// agent session. Query: session_id (required), window, limit, cursor.
export function listSessionSteps(query) {
  return adminApi('GET', '/v1/llm/sessions/steps', { query });
}

// Returns { agent_session_id, items, next_cursor }: the session's retained
// trace records, each with its integrity `verification`.
export function listSessionRecords(query) {
  return adminApi('GET', '/v1/llm/sessions/records', { query });
}
