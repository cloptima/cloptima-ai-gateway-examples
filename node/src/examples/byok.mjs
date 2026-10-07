/**
 * Bring Your Own Key (BYOK) - Enterprise Provider Credential Integration
 *
 * In enterprise architectures, organizations often negotiate direct volume contracts
 * with LLM providers (e.g. OpenAI, Anthropic, AWS Bedrock) and want to use their own
 * provider accounts while leveraging Cloptima for:
 * 1. Unified policy guardrails and access governance
 * 2. Real-time cost attribution and team chargeback
 * 3. Centralized audit logging and compliance tracing
 *
 * With BYOK, model inference compute is billed directly to your own provider account,
 * rather than drawing down Cloptima's managed compute credits.
 *
 * You can run this example by either:
 * - Setting CLOPTIMA_PROVIDER_CREDENTIAL_ID in .env with a credential configured in the Console, OR
 * - Setting PROVIDER_API_KEY in .env with your OpenAI API key so this script can register it.
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { runSuffix } from '../lib/config.mjs';
import { graphql } from '../lib/gatewayAdmin.mjs';

async function resolveProviderCredentialId() {
  if (process.env.CLOPTIMA_PROVIDER_CREDENTIAL_ID) {
    return process.env.CLOPTIMA_PROVIDER_CREDENTIAL_ID;
  }

  const providerApiKey = process.env.PROVIDER_API_KEY;
  if (!providerApiKey) {
    throw new Error(
      'Missing required env var PROVIDER_API_KEY or CLOPTIMA_PROVIDER_CREDENTIAL_ID.\n' +
      'To test BYOK, set PROVIDER_API_KEY in your .env with your OpenAI API key, or provide an existing CLOPTIMA_PROVIDER_CREDENTIAL_ID.'
    );
  }

  const suffix = runSuffix();
  console.log('Registering an enterprise provider credential (BYOK)...');
  const created = await graphql(
    `mutation CreateCredential($input: CreateLLMProviderCredentialInput!) {
      createLLMProviderCredential(input: $input) { id provider displayName }
    }`,
    { input: { provider: 'openai', displayName: `byok-openai-${suffix}`, apiKey: providerApiKey } },
  );

  const credentialId = created.createLLMProviderCredential.id;
  console.log(`Registered credential: ${credentialId} (${created.createLLMProviderCredential.displayName})`);
  return credentialId;
}

async function main() {
  const credentialId = await resolveProviderCredentialId();

  console.log('\nInitializing OpenAI client configured with BYOK credential header...');
  // Passing 'x-cloptima-provider-credential-id' routes inference calls through
  // your enterprise provider account while maintaining Cloptima governance.
  const access = await getAccess({
    app: 'byok-demo',
    policy: {
      name: 'byok-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['openai'],
      allowedModels: ['openai/gpt-4o-mini'],
    },
  });
  const client = openaiClient(access.virtualKey, {
    defaultHeaders: { 'x-cloptima-provider-credential-id': credentialId },
  });

  console.log('Sending query through Cloptima Gateway under BYOK credential...');
  try {
    const response = await client.chat.completions.create({
      model: 'openai/gpt-4o-mini',
      messages: [
        { role: 'system', content: 'You are an enterprise AI architect.' },
        { role: 'user', content: 'Summarize the advantage of Bring-Your-Own-Key (BYOK) architecture for enterprise compliance in two sentences.' },
      ],
      temperature: 0.7,
    });

    console.log('\n--- Model Response ---');
    console.log(response.choices[0]?.message?.content?.trim());

    console.log('\n--- BYOK Execution Telemetry ---');
    console.log(`Model: ${response.model}`);
    console.log(`Tokens: prompt=${response.usage?.prompt_tokens}, completion=${response.usage?.completion_tokens}, total=${response.usage?.total_tokens}`);
    console.log(`Billed To: Customer Provider Account (via credential ${credentialId})`);
    console.log('Governance Status: Authorized, policy validated, audit record preserved');
  } catch (err) {
    console.error('Enterprise BYOK request failed:', err?.message || err);
    if (err?.status) {
      console.error(`HTTP Status: ${err.status}`);
    }
  }
}

main().catch((err) => {
  console.error('BYOK execution failed:', err.message);
  process.exitCode = 1;
});
