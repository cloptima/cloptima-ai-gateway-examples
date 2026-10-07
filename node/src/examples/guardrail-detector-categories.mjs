/**
 * Multi-Provider Managed Guardrail Scans
 *
 * Demonstrates how Cloptima policies integrate with third-party cloud security providers
 * (Google Model Armor, Azure AI Content Safety, Amazon Bedrock Guardrails) using
 * Cloptima-managed credentials.
 *
 * Prerequisite:
 * - Requires available Cloptima managed credits because external provider scans are billable.
 *
 * Run standalone:
 *   node src/examples/guardrail-detector-categories.mjs
 * Choose a provider with GUARDRAIL_PROVIDER (default google-model-armor):
 *   GUARDRAIL_PROVIDER=azure-content-safety node src/examples/guardrail-detector-categories.mjs
 *   GUARDRAIL_PROVIDER=bedrock-guardrails node src/examples/guardrail-detector-categories.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { CONSOLE } from '../lib/config.mjs';
import { MODELS } from '../lib/models.mjs';

const PROVIDERS = {
  'google-model-armor': {
    id: 'google-model-armor',
    name: 'Google Model Armor',
    integration: {
      kind: 'google_model_armor',
      credential_source: 'cloptima_managed',
      scan_directions: 'input',
    },
  },
  'azure-content-safety': {
    id: 'azure-content-safety',
    name: 'Azure AI Content Safety',
    integration: {
      kind: 'azure_content_safety',
      credential_source: 'cloptima_managed',
      prompt_shields_enabled: true,
      harm_categories: ['Hate', 'Violence'],
      scan_directions: 'input',
    },
  },
  'bedrock-guardrails': {
    id: 'bedrock-guardrails',
    name: 'Amazon Bedrock Guardrails',
    integration: {
      kind: 'bedrock_guardrails',
      credential_source: 'cloptima_managed',
      scan_directions: 'input',
    },
  },
};

function profileInput(name, integration) {
  return {
    name,
    description: 'Managed provider scan integration example',
    definition: {
      input: { action: 'observe', detectors: { secret: {} } },
      output: { action: 'observe', detectors: { secret: {} } },
      provider_integration: integration,
    },
  };
}

async function main() {
  console.log('=== Multi-Provider Managed Guardrail Evaluation ===\n');
  console.log('Prerequisite: The account must have managed credits available for billable guardrail scans.\n');

  const selectedKey = process.env.GUARDRAIL_PROVIDER || 'google-model-armor';
  const provider = PROVIDERS[selectedKey];
  if (!provider) {
    throw new Error(`Unknown GUARDRAIL_PROVIDER "${selectedKey}". Use one of: ${Object.keys(PROVIDERS).join(', ')}.`);
  }
  console.log(`Active Provider Integration: ${provider.name}`);

  // Governance setup: a guardrail profile with the selected managed provider scan attached
  // to the policy this application runs under. Skipped when CLOPTIMA_VIRTUAL_KEY is set.
  const access = await getAccess({
    app: `guardrail-${provider.id}-demo`,
    guardrailProfile: profileInput(`guardrail-${provider.id}-profile`, provider.integration),
    policy: {
      name: `guardrail-${provider.id}-policy`,
      mode: 'enforce',
      budgetMode: 'hard',
      failMode: 'fail_closed',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
    },
  });

  // Application code: official SDK pointed at the gateway with virtual key.
  const client = openaiClient(access.virtualKey);

  console.log('\nSending request through guarded route (pre-flight scan active)...');
  try {
    const response = await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: 'Confirm this request passed safety scan.' }],
    });

    console.log(`  ✓ Scan completed & response served: "${response.choices[0].message.content.trim()}"`);
    console.log(`  Tokens: ${response.usage?.total_tokens} | Request ID: ${response.id}`);
  } catch (err) {
    if (err.status === 403) {
      console.log(`  🛡️ Gateway Security Block (HTTP 403)`);
      console.log(`  Reason: ${err.error?.reason || err.message}`);
      console.log(`  Violations: ${(err.error?.violations || []).join(', ')}`);
    } else {
      console.log(`  Request error: ${err.message}`);
    }
  }

  console.log(`\nReview guardrail scan events in the Cloptima Console:`);
  console.log(`  - Audit Trail: ${CONSOLE.audit}`);
  console.log(`  - Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
