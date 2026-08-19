// The policy, binding, and virtual key an example creates are the entire
// contract. These confirm the gateway honoured that contract and stop the
// script with a specific message when it did not, so a run where enforcement
// quietly stopped working can never print as a success.
//
// Nothing here asks the gateway to enforce anything. No header, flag, or
// counter is sent - the only input is the configuration registered above.

function detail(result) {
  const status = result?.status ? ` status=${result.status}` : '';
  const reason = result?.reason == null
    ? ''
    : ` reason=${typeof result.reason === 'string' ? result.reason : JSON.stringify(result.reason)}`;
  return `outcome=${result?.outcome ?? 'undefined'}${status}${reason}`;
}

function mentions(result, violation) {
  const reason = result?.reason;
  const text = typeof reason === 'string' ? reason : JSON.stringify(reason ?? '');
  return text.toLowerCase().includes(String(violation).toLowerCase());
}

export function confirmAllowed(result, what) {
  if (result?.outcome !== 'allowed') {
    throw new Error(`${what}: expected this call to be served, got ${detail(result)}`);
  }
  return result;
}

export function confirmBlocked(result, what, { status, violation } = {}) {
  if (result?.outcome !== 'blocked') {
    throw new Error(`${what}: expected the gateway to block this call, got ${detail(result)}`);
  }
  if (status !== undefined && result.status !== status) {
    throw new Error(`${what}: expected HTTP ${status}, got ${detail(result)}`);
  }
  if (violation && !mentions(result, violation)) {
    throw new Error(`${what}: expected the block to name "${violation}", got ${detail(result)}`);
  }
  return result;
}

// For caps that admit traffic up to a threshold and then stop it. Returns how
// many calls got through, so the example reports the real number rather than
// assuming the cap fired.
export function confirmCapStopped(results, what, { status, violation, expectedAllowed } = {}) {
  const index = results.findIndex((result) => result.outcome !== 'allowed');
  if (index === -1) {
    throw new Error(
      `${what}: expected the cap to stop a call, but all ${results.length} were served. `
      + 'The limit is set on the policy and these calls ran under a key bound to it.',
    );
  }
  confirmBlocked(results[index], what, { status, violation });
  if (expectedAllowed !== undefined && index !== expectedAllowed) {
    throw new Error(`${what}: expected ${expectedAllowed} calls to be served before the cap, got ${index}`);
  }
  return { allowedCount: index, blocked: results[index] };
}

export function confirmEquals(actual, expected, what) {
  if (actual !== expected) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
  return actual;
}
