// Creates an isolated policy-bound profile for each managed scan provider.
// Requires available Cloptima managed credits because each scan is billable.
// Run standalone:
//   node src/examples/guardrail-detector-categories.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { graphql, createGuardrailProfile, createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { confirmAllowed } from '../lib/confirm.mjs';
import { MODELS } from '../lib/models.mjs';

const PROVIDERS = [
  {
    id: 'google-model-armor',
    name: 'Google Model Armor',
    integration: {
      kind: 'google_model_armor', credential_source: 'cloptima_managed', scan_directions: 'input',
    },
  },
  {
    id: 'azure-content-safety',
    name: 'Azure AI Content Safety',
    integration: {
      kind: 'azure_content_safety', credential_source: 'cloptima_managed',
      prompt_shields_enabled: true, harm_categories: ['Hate', 'Violence'], scan_directions: 'input',
    },
  },
  {
    id: 'bedrock-guardrails',
    name: 'Amazon Bedrock Guardrails',
    integration: {
      kind: 'bedrock_guardrails', credential_source: 'cloptima_managed', scan_directions: 'input',
    },
  },
];

function profileInput(name, integration) {
  return {
    name,
    description: 'Managed provider scan validation example',
    definition: {
      input: { action: 'observe', detectors: { secret: {} } },
      output: { action: 'observe', detectors: { secret: {} } },
      provider_integration: integration,
    },
  };
}

async function removeTemporaryResources({ binding, policy, profile, key }) {
  const actions = [
    [binding, 'binding', (id) => graphql('mutation($id: ID!) { deleteLLMGatewayPolicyBinding(id: $id) }', { id })],
    [policy, 'policy', (id) => graphql('mutation($id: ID!) { deleteLLMGatewayPolicy(id: $id) }', { id })],
    [profile, 'profile', (id) => graphql('mutation($id: ID!) { deleteLLMGuardrailProfile(id: $id) }', { id })],
    [key, 'key', (id) => graphql('mutation($id: ID!) { revokeLLMGatewayKey(id: $id) }', { id })],
  ];
  const errors = [];
  for (const [resource, label, remove] of actions) {
    if (!resource?.id) continue;
    try {
      await remove(resource.id);
    } catch (err) {
      errors.push(`${label}: ${err.message}`);
    }
  }
  return errors;
}

async function main() {
  const suffix = runSuffix();
  console.log('Creating one fail-closed profile and policy per managed scan provider...');
  console.log('Prerequisite: the account must have managed credits available for billable guardrail scans.');
  const failures = [];
  for (const [index, provider] of PROVIDERS.entries()) {
    let profile;
    let policy;
    let key;
    let binding;
    try {
      const resourceName = `guardrail-${provider.id}-${suffix}`;
      const appId = resourceName;
      profile = await createGuardrailProfile(profileInput(resourceName, provider.integration));
      policy = await createPolicy({
        name: resourceName,
        mode: 'enforce', budgetMode: 'hard_fast', failMode: 'fail_closed',
        allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
        guardrailProfileId: profile.id,
      });
      key = await createVirtualKey({
        name: `vk-${resourceName}`, teamId: 'Platform AI', appId, environment: 'dev',
      });
      binding = await createBinding({
        policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev',
        priority: 10, acknowledgeOverlap: true,
      });
      const client = openaiStyleClient(key.accessToken, config.baseUrl);
      const result = await callOpenAIStyle(client, {
        model: MODELS.default,
        prompt: 'Reply with exactly: guardrail scan passed.',
        label: provider.name,
      });
      console.log(`[${result.outcome}] ${provider.name}: ${result.status ?? 'served'}${result.reason ? ` (${JSON.stringify(result.reason)})` : ''}`);
      confirmAllowed(result, `${provider.name} scan completed under a fail-closed policy`);
      if (index === PROVIDERS.length - 1) {
        console.log(`  retained for review - profile: ${profile.id}; policy: ${policy.id}; app: ${appId}`);
      }
    } catch (err) {
      failures.push(`${provider.name}: ${err.message}`);
    } finally {
      if (index < PROVIDERS.length - 1) {
        const cleanupErrors = await removeTemporaryResources({ binding, policy, profile, key });
        if (cleanupErrors.length) failures.push(`${provider.name} cleanup: ${cleanupErrors.join('; ')}`);
      }
    }
  }

  if (failures.length) {
    throw new Error(`One or more provider checks failed:\n- ${failures.join('\n- ')}`);
  }
  console.log('\nAll three isolated managed provider scans completed successfully.');
  console.log(`Review policy and request records in the console: ${CONSOLE.policies} and ${CONSOLE.audit}`);
}

main().catch((err) => {
  console.error('guardrail-detector-categories failed:', err);
  process.exitCode = 1;
});
