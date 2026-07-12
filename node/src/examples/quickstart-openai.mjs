// Simplest possible working call: mint a policy + virtual key, then call the
// gateway using the official OpenAI SDK. Run standalone:
//   node src/examples/quickstart-openai.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

async function main() {
  const suffix = runSuffix();
  const appId = `quickstart-openai-${suffix}`;

  console.log(`Creating policy allowing ${MODELS.default} on the managed Vertex AI provider...`);
  const policy = await createPolicy({
    name: `quickstart-openai-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: [MODELS.default],
  });
  console.log(`  policy ${policy.name} -> ${policy.id}`);

  console.log('Minting a virtual key scoped to this policy...');
  const key = await createVirtualKey({
    name: `vk-quickstart-openai-${suffix}`,
    teamId: 'Quickstart', appId, environment: 'dev',
  });
  console.log(`  key ${key.id}`);

  await createBinding({ policyId: policy.id, teamId: 'Quickstart', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log('Bound. Calling the gateway with the official OpenAI SDK...');

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const result = await callOpenAIStyle(client, {
    model: MODELS.default,
    prompt: 'In one sentence, confirm this call went through Cloptima\'s managed AI gateway.',
    headers: { 'x-cloptima-team': 'Quickstart', 'x-cloptima-app': appId, 'x-cloptima-environment': 'dev' },
    label: 'quickstart-openai',
  });

  console.log(`\n[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  console.log(`\nEvidence: Explorer tab (${CONSOLE.spend}) - find this request_id to see attributed spend and usage.`);
}

main().catch((err) => {
  console.error('quickstart-openai failed:', err);
  process.exitCode = 1;
});
