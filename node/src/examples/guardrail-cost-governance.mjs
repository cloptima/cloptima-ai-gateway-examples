// Guardrail cost-governance: guardrailCostMode governs
// whether the gateway will run a heavier (and costlier) provider-backed
// detector scan per request, and guardrailCostExceededAction decides what
// happens when that scan's cost would exceed guardrailMaxCostPerRequestCents.
// Deliberately pins a tiny cost cap (mirrors budget-limit.mjs's "pin a small
// threshold to keep the knob meaningful" pattern) so cost-exceeded behavior
// triggers deterministically, then enables guardrailLightweightProfileEnabled
// so 'downgrade' has a cheaper profile to fall back to instead of failing
// closed. All cost-tuning fields are Enterprise-gated (llm_guardrail_enterprise),
// so this is wrapped in try/catch to show that gate too on a non-Enterprise customer.
// Run standalone:
//   node src/examples/guardrail-cost-governance.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

// Illustrative, not a platform minimum. Deliberately tiny so any heavier
// provider-backed scan exceeds it and the cost-exceeded action is exercised.
const MAX_COST_PER_REQUEST_CENTS = 1;

async function main() {
  const suffix = runSuffix();
  const appId = `guardrail-cost-governance-${suffix}`;

  console.log(`Creating a policy with guardrailCostMode='enforce', a $${MAX_COST_PER_REQUEST_CENTS}-cent cap, and downgrade-to-lightweight on exceed...`);
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
    console.log('Expected (non-Enterprise customer): guardrail cost-tuning fields require the llm_guardrail_enterprise entitlement. Nothing further to demonstrate without it.');
    return;
  }
  const key = await createVirtualKey({ name: `vk-guardrail-cost-governance-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Making a call that should trip the cost-exceeded downgrade...\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const result = await callOpenAIStyle(client, {
    model: MODELS.default,
    prompt: 'In one sentence, confirm this call ran under a guardrail cost-governance policy.',
    headers: { 'x-cloptima-team': 'Platform AI', 'x-cloptima-app': appId, 'x-cloptima-environment': 'dev' },
    label: 'cost-governance-probe',
  });

  console.log(`[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  console.log(
    `\nExpected: allowed - the ${MAX_COST_PER_REQUEST_CENTS}-cent cap is exceeded by the full detector scan, so the `
    + "request is served via the cheaper guardrailLightweightProfileEnabled fallback rather than blocked outright "
    + "(guardrailCostExceededAction: 'downgrade'). Re-run with guardrailCostExceededAction: 'block' to see the deny "
    + "path instead, or 'require_approval' to route it through the LLMGatewayApproval governance queue.",
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - the record shows the cost-exceeded downgrade decision; Dashboard tab (${CONSOLE.dashboard}) surfaces guardrailCostUsd/guardrailAvoidedCostUsd.`);
}

main().catch((err) => {
  console.error('guardrail-cost-governance failed:', err);
  process.exitCode = 1;
});
