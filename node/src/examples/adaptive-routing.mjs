// Adaptive routing (certification/candidate contract, deterministic
// routing decision, canary cohorts) configures a certified set of candidate
// models per cost/latency tier under policy.metadata.routing.adaptive, a
// JSON object passed as policy metadata the same way route/fallback/cache
// controls are.
//
// This scopes to 'observe' mode: the router evaluates and logs which
// candidate it would have picked for each call, without actually changing
// where traffic goes - actual per-call routing decisions aren't visible in
// this script's own output (see the console evidence line below). Moving to
// 'canary' or 'enforce' additionally requires an approved_eval_id and an
// approved_release_gate_id - i.e. a passed eval run (prompt-release-workflow.mjs)
// plus a DECIDED release-gate approval - and deciding that approval is the
// same kind of human-review step this repo's examples don't script (see
// approval-workflow.mjs), so canary/enforce aren't demonstrated here.
// Run standalone:
//   node src/examples/adaptive-routing.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS, OTHER_GEMINI_MODELS } from '../lib/models.mjs';

const CANDIDATE_MODELS = {
  cheap: [OTHER_GEMINI_MODELS['gemini-2.5-flash-lite']],
  balanced: [MODELS.default],
  strong: [OTHER_GEMINI_MODELS['gemini-2.5-pro']],
};

async function main() {
  const suffix = runSuffix();
  const appId = `adaptive-routing-${suffix}`;

  console.log('Creating a policy with adaptive routing in observe mode across cheap/balanced/strong candidate tiers...');
  const policy = await createPolicy({
    name: `adaptive-routing-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: [...CANDIDATE_MODELS.cheap, ...CANDIDATE_MODELS.balanced, ...CANDIDATE_MODELS.strong],
    metadata: {
      routing: {
        adaptive: {
          mode: 'observe',
          route_risk_ceiling: 'low',
          candidate_set_version: `v${suffix}`,
          candidate_models: CANDIDATE_MODELS,
        },
      },
    },
  });
  const key = await createVirtualKey({ name: `vk-adaptive-routing-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Sending a few calls at the 'balanced' tier model...\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const results = [];
  for (let i = 0; i < 3; i += 1) {
    const result = await callOpenAIStyle(client, {
      model: MODELS.default,
      prompt: `Routing probe ${i + 1}. In one sentence, confirm this call went through.`,
      label: `routing-probe-${i + 1}`,
    });
    results.push(result);
    console.log(`  [${result.outcome}] routing-probe-${i + 1}`);
  }

  console.log(
    '\nExpected: all 3 calls are served exactly as requested (observe mode never changes actual routing) - the '
    + "router logs, per call, which candidate it would have picked under this certified tier set. That decision "
    + "log isn't in this script's own output; it's a console-side evidence trail.",
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - shows the logged routing-decision trail per call; Policies tab (${CONSOLE.policies}) shows the metadata.routing.adaptive config, including the candidate tiers above.`);
  console.log(JSON.stringify(results, null, 2));
}

main().catch((err) => {
  console.error('adaptive-routing failed:', err);
  process.exitCode = 1;
});
