// Sets a per-request scan cost cap in a provider-backed guardrail profile.
// The billable managed scan requires available Cloptima managed credits.
// Run standalone: node src/examples/guardrail-cost-governance.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createGuardrailProfile, createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { confirmAllowed } from '../lib/confirm.mjs';
import { MODELS } from '../lib/models.mjs';

const MAX_COST_PER_REQUEST_CENTS = 1;

async function main() {
  const suffix = runSuffix();
  const appId = `guardrail-cost-governance-${suffix}`;
  console.log('Prerequisite: the account must have managed credits available for this billable guardrail scan.');
  const profile = await createGuardrailProfile({
    name: `guardrail-cost-governance-${suffix}`,
    description: 'Managed Model Armor scan with a per-request cost cap',
    definition: {
      input: { action: 'observe', detectors: { secret: {} } },
      output: { action: 'observe', detectors: { secret: {} } },
      provider_integration: {
        kind: 'google_model_armor', credential_source: 'cloptima_managed', scan_directions: 'input',
      },
      cost: { mode: 'enforce', max_cost_per_request_cents: MAX_COST_PER_REQUEST_CENTS, exceeded_action: 'block' },
    },
  });
  const policy = await createPolicy({
    name: `guardrail-cost-governance-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast', failMode: 'fail_closed',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default], guardrailProfileId: profile.id,
  });
  const key = await createVirtualKey({
    name: `vk-guardrail-cost-governance-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev',
  });
  await createBinding({
    policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true,
  });

  const result = await callOpenAIStyle(openaiStyleClient(key.accessToken, config.baseUrl), {
    model: MODELS.default,
    prompt: 'Reply with exactly: scan cost is within the configured cap.',
    label: 'cost-governance-probe',
  });
  console.log(`[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  confirmAllowed(result, 'provider scan stayed within the configured cost cap');
  console.log(`\nConfirmed: the profile's ${MAX_COST_PER_REQUEST_CENTS}-cent cap admitted this scan.`);
  console.log(`Profile: ${profile.id}; policy: ${policy.id}; review them in ${CONSOLE.policies} and ${CONSOLE.audit}`);
}

main().catch((err) => {
  console.error('guardrail-cost-governance failed:', err);
  process.exitCode = 1;
});
