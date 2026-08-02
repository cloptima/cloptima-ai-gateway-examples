// Uses the ai:admin key to bring your own provider credential: create it,
// test it, then route one managed-gateway call through it so your own key
// gets Cloptima's governance/attribution/telemetry layer on top - billed to
// your own provider account, not Cloptima's managed-credits wallet.
// Requires PROVIDER_API_KEY (your own OpenAI-compatible key) in .env.
// Run standalone:
//   node src/examples/byok.mjs
import { config, runSuffix, USER_AGENT, CONSOLE } from '../lib/config.mjs';
import { graphql, createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var ${name} - set your own provider API key in .env.`);
  return value;
}

async function main() {
  const providerApiKey = required('PROVIDER_API_KEY');
  const suffix = runSuffix();
  const appId = `byok-${suffix}`;

  console.log('Creating a provider credential (BYOK)...');
  const created = await graphql(
    `mutation CreateCredential($input: CreateLLMProviderCredentialInput!) {
      createLLMProviderCredential(input: $input) { id provider displayName }
    }`,
    { input: { provider: 'openai', displayName: `byok-openai-${suffix}`, apiKey: providerApiKey } },
  );
  const credentialId = created.createLLMProviderCredential.id;
  console.log(`Created credential ${credentialId} (${created.createLLMProviderCredential.displayName})`);

  console.log('Testing the credential against a model...');
  const tested = await graphql(
    `mutation TestCredential($id: ID!, $input: TestLLMProviderCredentialInput) {
      testLLMProviderCredential(id: $id, input: $input) { id provider displayName }
    }`,
    { id: credentialId, input: { model: 'gpt-4o-mini' } },
  );
  console.log('Credential test result:', JSON.stringify(tested.testLLMProviderCredential, null, 2));

  console.log('Creating a policy allowing the BYOK provider/model and minting a key...');
  const policy = await createPolicy({
    name: `byok-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['openai'], allowedModels: ['openai/gpt-4o-mini'],
  });
  const key = await createVirtualKey({ name: `vk-byok-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Making one managed-gateway call routed through the BYOK credential...\n`);

  const response = await fetch(`${config.baseUrl}/v1/ai/chat/completions`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'user-agent': USER_AGENT,
      authorization: `Bearer ${key.accessToken}`,
      'x-cloptima-provider-credential-id': credentialId,
      'x-cloptima-team': 'Platform AI',
      'x-cloptima-app': appId,
      'x-cloptima-environment': 'dev',
    },
    body: JSON.stringify({
      model: 'openai/gpt-4o-mini',
      messages: [{ role: 'user', content: 'In one sentence, confirm this call used a bring-your-own-key provider credential.' }],
    }),
  });
  const body = await response.json();
  console.log(`Gateway response status=${response.status}`);
  console.log(JSON.stringify(body, null, 2));

  console.log(
    '\nThis call is billed to your own provider account, not Cloptima\'s managed-credit wallet.',
  );
  console.log(`Evidence: Credentials tab (${CONSOLE.credentials}) shows the provider credential just created; Audit tab (${CONSOLE.audit}) and Explorer tab (${CONSOLE.spend}) confirm attribution/telemetry are still captured even though spend is BYOK.`);
}

main().catch((err) => {
  console.error('byok failed:', err);
  process.exitCode = 1;
});
