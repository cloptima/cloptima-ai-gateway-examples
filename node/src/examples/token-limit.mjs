// Creates a policy with a realistic maxOutputTokens cap - well above the
// platform floor of 64 - and shows a long-response request get blocked
// pre-flight rather than silently truncated.
// Run standalone:
//   node src/examples/token-limit.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

// Illustrative, not a platform minimum - the platform floor is 64. Change
// this and re-run to see the cap move.
const MAX_OUTPUT_TOKENS = 200;

async function main() {
  const suffix = runSuffix();
  const appId = `token-limit-${suffix}`;

  console.log(`Creating policy with maxOutputTokens=${MAX_OUTPUT_TOKENS}...`);
  const policy = await createPolicy({
    name: `token-limit-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: [MODELS.default],
    maxOutputTokens: MAX_OUTPUT_TOKENS,
  });
  const key = await createVirtualKey({ name: `vk-token-limit-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Requesting a long response the policy should reject...\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const result = await callOpenAIStyle(client, {
    model: MODELS.default,
    prompt: 'Write a detailed 500-word essay about the history of cloud computing.',
    headers: { 'x-cloptima-team': 'Platform AI', 'x-cloptima-app': appId, 'x-cloptima-environment': 'dev' },
    label: 'token-limit-probe',
  });

  console.log(`[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  console.log(
    `\nExpected: blocked pre-flight (403) since the request's default max_tokens exceeds ${MAX_OUTPUT_TOKENS}, ` +
    'with both the requested and allowed values named in the error.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - the block record names both the requested and allowed token values; Policies tab (${CONSOLE.policies}) shows the maxOutputTokens config.`);
}

main().catch((err) => {
  console.error('token-limit failed:', err);
  process.exitCode = 1;
});
