// Creates a policy with a realistic per-minute request rate cap, fires calls
// fast enough to exceed it, and shows the 429 once the cap is hit.
// Run standalone:
//   node src/examples/rate-limit.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

// Illustrative, not a platform minimum - change this and re-run to see the
// cap move. Bounds: requestRateLimitPerMinute accepts 1-1,000,000.
const REQUEST_RATE_LIMIT_PER_MINUTE = 20;
const CALLS_TO_FIRE = 25;

async function main() {
  const suffix = runSuffix();
  const appId = `rate-limit-${suffix}`;

  console.log(`Creating policy with requestRateLimitPerMinute=${REQUEST_RATE_LIMIT_PER_MINUTE}...`);
  const policy = await createPolicy({
    name: `rate-limit-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: [MODELS.default],
    requestRateLimitPerMinute: REQUEST_RATE_LIMIT_PER_MINUTE,
  });
  const key = await createVirtualKey({ name: `vk-rate-limit-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Firing ${CALLS_TO_FIRE} calls back-to-back...\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const results = [];
  for (let i = 0; i < CALLS_TO_FIRE; i += 1) {
    const result = await callOpenAIStyle(client, {
      model: MODELS.default,
      prompt: `Rate limit probe ${i + 1}. Reply with just "ok".`,
      headers: { 'x-cloptima-team': 'Platform AI', 'x-cloptima-app': appId, 'x-cloptima-environment': 'dev' },
      label: `call-${i + 1}`,
    });
    results.push(result);
    console.log(`  [${result.outcome}] call-${i + 1} status=${result.status ?? 200}`);
    if (result.outcome !== 'allowed') break;
  }

  const allowedCount = results.filter((r) => r.outcome === 'allowed').length;
  console.log(`\n${allowedCount} calls allowed before the ${REQUEST_RATE_LIMIT_PER_MINUTE}/minute cap returned 429.`);
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - filter by app "${appId}" for the 429 block record; Policies tab (${CONSOLE.policies}) shows the requestRateLimitPerMinute config that fired.`);
  console.log(JSON.stringify(results, null, 2));
}

main().catch((err) => {
  console.error('rate-limit failed:', err);
  process.exitCode = 1;
});
