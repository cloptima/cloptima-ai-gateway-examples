// Creates a Vertex-only policy and requests a non-Vertex model through it,
// showing a provider-scope block rather than a silent fallback.
// Run standalone:
//   node src/examples/provider-deny.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { confirmBlocked } from '../lib/confirm.mjs';
import { MODELS } from '../lib/models.mjs';

async function main() {
  const suffix = runSuffix();
  const appId = `provider-deny-${suffix}`;

  // 1. Cloptima setup - the policy, key, and binding are the whole contract.
  console.log('Creating a Vertex-only policy...');
  const policy = await createPolicy({
    name: `provider-deny-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
  });
  const key = await createVirtualKey({ name: `vk-provider-deny-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Requesting a non-Vertex model through it...\n`);

  // 2. Your application code - the official OpenAI SDK, unchanged.
  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const result = await callOpenAIStyle(client, {
    model: 'openai/gpt-4o',
    prompt: 'This call should be denied - non-Vertex provider.',
    label: 'provider-deny-probe',
  });

  // 3. What the gateway did. confirmBlocked stops the script if the policy
  // above was not held, so a silent regression cannot print as a success.
  console.log(`[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  confirmBlocked(result, 'allowedProviders=[vertex_ai]', { status: 403, violation: 'provider is not allowed' });
  console.log(`\nConfirmed: blocked (${result.status}) - the policy only allows vertex_ai, so a non-Vertex model is denied before provider egress.`);
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - filter by app "${appId}" for the provider-scope block record.`);
}

main().catch((err) => {
  console.error('provider-deny failed:', err);
  process.exitCode = 1;
});
