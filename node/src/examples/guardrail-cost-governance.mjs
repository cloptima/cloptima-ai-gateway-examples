// Guardrail cost-governance: guardrailCostMode, guardrailMaxCostPerRequestCents,
// and guardrailCostExceededAction govern the cost of an optional heavier
// provider-backed guardrail scan (guardrailProviderIntegration: webhook /
// azure_content_safety / bedrock_guardrails) - downgrading to a lightweight
// profile, requiring approval, or blocking when that scan would cost too much.
// This example uses only the built-in pii/secret detectors, which run locally
// at zero cost, so it demonstrates the cost-tuning fields being accepted
// (requires the Enterprise guardrails plan) rather than the downgrade itself
// firing - see guardrail-detector-categories.mjs for configuring a
// provider-backed scan.
// Run standalone:
//   node src/examples/guardrail-cost-governance.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { confirmAllowed } from '../lib/confirm.mjs';
import { MODELS } from '../lib/models.mjs';

// Illustrative, not a platform minimum. No provider-backed scan is configured
// below, so this cap is never actually exercised - it only shows the field
// being accepted.
const MAX_COST_PER_REQUEST_CENTS = 1;

async function main() {
  const suffix = runSuffix();
  const appId = `guardrail-cost-governance-${suffix}`;

  console.log(`Creating a policy with guardrailCostMode='enforce', a $${MAX_COST_PER_REQUEST_CENTS}-cent cap, and guardrailCostExceededAction='downgrade'...`);
  let policy;
  try {
    policy = await createPolicy({
      name: `guardrail-cost-governance-${suffix}`,
      mode: 'enforce', budgetMode: 'hard_fast',
      allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
      guardrailDetectorsEnabled: ['pii', 'secret'],
      guardrailOutputAction: 'redact',
      guardrailCostMode: 'enforce',
      guardrailMaxCostPerRequestCents: MAX_COST_PER_REQUEST_CENTS,
      guardrailRequiredRiskTier: 'low',
      guardrailCostExceededAction: 'downgrade',
      guardrailLightweightProfileEnabled: true,
    });
  } catch (err) {
    console.log(`  denied: ${err.message}`);
    console.log('Expected (non-Enterprise plan): guardrail cost-tuning fields require the Enterprise guardrails plan. Nothing further to demonstrate without it.');
    return;
  }
  const key = await createVirtualKey({ name: `vk-guardrail-cost-governance-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Making a call under this policy...\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const result = await callOpenAIStyle(client, {
    model: MODELS.default,
    prompt: 'In one sentence, confirm this call ran under a guardrail cost-governance policy.',
    label: 'cost-governance-probe',
  });

  // 3. What the gateway did. The cost cap only applies to a provider-backed
  // scan; pii/secret detectors are local and free, so the call is served
  // normally either way.
  console.log(`[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  confirmAllowed(result, 'served under a guardrail cost-governance policy');
  console.log(
    `\nConfirmed: served - guardrailMaxCostPerRequestCents=${MAX_COST_PER_REQUEST_CENTS} was accepted by the policy. `
    + "With only local pii/secret detectors enabled, there's no provider-backed scan cost to cap here; add a "
    + "guardrailProviderIntegration (see guardrail-detector-categories.mjs) to see the downgrade/require_approval/block "
    + 'action trigger.',
  );
  console.log(`Evidence: Policies tab (${CONSOLE.policies}) shows the saved guardrailCostMode/guardrailMaxCostPerRequestCents/guardrailCostExceededAction config.`);
}

main().catch((err) => {
  console.error('guardrail-cost-governance failed:', err);
  process.exitCode = 1;
});
