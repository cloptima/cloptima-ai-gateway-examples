// Creates a hard_strict policy with a small but real per-policy daily budget,
// distinct from the org-wide managed-credits wallet cap, and fires calls in
// a loop until the budget denies the rest.
//
// hard_strict reserves against an ESTIMATED cost derived from the request's
// max_tokens (a pessimistic worst case), not the realized post-completion
// cost - so this script passes an explicit, modest max_tokens on every call
// to keep that estimate small and consistent. Without that, an unbounded
// default max_tokens would make the very first call's estimate blow past a
// small budget and trip on call 1 regardless of the budget's actual size.
// Run standalone:
//   node src/examples/budget-limit.mjs
import { config, runSuffix, USER_AGENT, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { MODELS } from '../lib/models.mjs';

// Illustrative, not a platform minimum. Bounds: dailyBudgetUsd accepts 0-10,000,000.
const DAILY_BUDGET_USD = 0.01;
const MAX_TOKENS_PER_CALL = 100;
const MAX_CALLS = 40;

async function callChat(virtualKey, { model, prompt, appId }) {
  const response = await fetch(`${config.baseUrl}/v1/ai/chat/completions`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'user-agent': USER_AGENT,
      authorization: `Bearer ${virtualKey}`,
      'x-cloptima-team': 'Platform AI',
      'x-cloptima-app': appId,
      'x-cloptima-environment': 'dev',
    },
    body: JSON.stringify({ model, max_tokens: MAX_TOKENS_PER_CALL, messages: [{ role: 'user', content: prompt }] }),
  });
  const body = await response.json().catch(() => null);
  return { status: response.status, body };
}

async function main() {
  const suffix = runSuffix();
  const appId = `budget-limit-${suffix}`;

  console.log(`Creating hard_strict policy with dailyBudgetUsd=$${DAILY_BUDGET_USD}...`);
  const policy = await createPolicy({
    name: `budget-limit-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_strict',
    allowedProviders: ['vertex_ai'],
    allowedModels: [MODELS.default],
    dailyBudgetUsd: DAILY_BUDGET_USD,
  });
  const key = await createVirtualKey({ name: `vk-budget-limit-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Firing calls (max ${MAX_CALLS}) until the budget denies...\n`);

  const results = [];
  for (let i = 0; i < MAX_CALLS; i += 1) {
    const { status, body } = await callChat(key.accessToken, {
      model: MODELS.default,
      prompt: `Budget probe ${i + 1}. Reply with just "ok".`,
      appId,
    });
    results.push({ label: `call-${i + 1}`, status, body });
    console.log(`  [${status === 200 ? 'allowed' : 'blocked'}] call-${i + 1} status=${status}`);
    if (status !== 200) break;
  }

  const allowedCount = results.filter((r) => r.status === 200).length;
  console.log(`\n${allowedCount} calls allowed before the $${DAILY_BUDGET_USD}/day policy budget returned 402.`);
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - filter by app "${appId}" for the 402 block record; Explorer tab (${CONSOLE.spend}) shows the spend accumulated right up to the cap.`);
  console.log(JSON.stringify(results, null, 2));
}

main().catch((err) => {
  console.error('budget-limit failed:', err);
  process.exitCode = 1;
});
