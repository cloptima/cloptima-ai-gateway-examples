// Creates a policy with a realistic maxOutputTokens cap - well above the
// platform floor of 64 - and shows a long-response request get blocked
// pre-flight rather than silently truncated.
// Run standalone:
//   node src/examples/token-limit.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { confirmBlocked } from '../lib/confirm.mjs';
import { MODELS } from '../lib/models.mjs';

// Illustrative, not a platform minimum - the platform floor is 64. Change
// this and re-run to see the cap move.
const MAX_OUTPUT_TOKENS = 200;

async function main() {
  const suffix = runSuffix();
  const appId = `token-limit-${suffix}`;

  // 1. Cloptima setup - the policy, key, and binding are the whole contract.
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

  // 2. Your application code - the official OpenAI SDK, unchanged.
  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const result = await callOpenAIStyle(client, {
    model: MODELS.default,
    prompt: 'Write a detailed 500-word essay about the history of cloud computing.',
    label: 'token-limit-probe',
  });

  // 3. What the gateway did. confirmBlocked stops the script if the policy
  // above was not held, so a silent regression cannot print as a success.
  console.log(`[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  confirmBlocked(result, `maxOutputTokens=${MAX_OUTPUT_TOKENS}`, { status: 403, violation: 'output limit' });
  console.log(
    `\nConfirmed: blocked pre-flight (${result.status}) - the request's default max_tokens exceeds ${MAX_OUTPUT_TOKENS}, ` +
    'and the error names both the requested and the allowed value.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - the block record names both the requested and allowed token values; Policies tab (${CONSOLE.policies}) shows the maxOutputTokens config.`);
}

main().catch((err) => {
  console.error('token-limit failed:', err);
  process.exitCode = 1;
});
