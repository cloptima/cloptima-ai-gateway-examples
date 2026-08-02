// Completes what exact-semantic-cache.mjs deliberately leaves at 'observe':
// semanticCacheMode: 'enforce' needs a per-(app, route, model-family) class
// approval (createLLMSemanticCacheClassApproval) on top of the policy flag,
// AND setting 'enforce' on the policy itself auto-queues a separate entry in
// the generic governance queue (LLMGatewayApproval, approvalType
// 'semantic_cache_enforce') that must be reviewed before enforcement actually
// activates - until then, effective behavior stays downgraded to 'suggest'.
// This script creates the class approval and shows the auto-queued entry
// pending; it does not review/approve it - that decision belongs to a second
// privileged identity in the console's Audit tab, not to the requester's own
// script. See ../../docs/CACHE_AND_POLICY.md.
// Run standalone:
//   node src/examples/semantic-cache-enforce.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { graphql, createPolicy, createVirtualKey, createBinding, listLLMGatewayApprovals } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

const ROUTE = '/v1/ai/chat/completions';
// The class approval's modelFamily must be keyed on the full canonical model
// ID (e.g. 'vertex_ai/gemini-2.5-flash'), not just its last path segment
// (e.g. 'gemini-2.5-flash') - modelFamily requires the full canonical model ID.
const MODEL_FAMILY = MODELS.default;

async function main() {
  const suffix = runSuffix();
  const appId = `semantic-cache-enforce-${suffix}`;

  console.log('Creating policy with exact cache (enforce) and semantic cache (enforce)...');
  const policy = await createPolicy({
    name: `semantic-cache-enforce-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    promptRetentionMode: 'full',
    exactCacheEnabled: true, exactCacheMode: 'enforce',
    semanticCacheEnabled: true, semanticCacheMode: 'enforce',
  });
  const key = await createVirtualKey({ name: `vk-semantic-cache-enforce-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound.\n`);

  console.log(`Requesting the class approval semantic-cache enforcement needs for (app=${appId}, route=${ROUTE}, modelFamily=${MODEL_FAMILY})...`);
  const classApprovalData = await graphql(
    `mutation CreateClassApproval($input: LLMSemanticCacheClassApprovalInput!) {
      createLLMSemanticCacheClassApproval(input: $input) { id appId route modelFamily createdAt }
    }`,
    { input: { appId, route: ROUTE, modelFamily: MODEL_FAMILY, notes: `semantic-cache-enforce example run ${suffix}` } },
  );
  console.log(`  class approval granted: ${JSON.stringify(classApprovalData.createLLMSemanticCacheClassApproval)}`);

  console.log('\nChecking the generic governance queue for the entry auto-queued by semanticCacheMode: \'enforce\'...');
  const pending = await listLLMGatewayApprovals({ status: 'pending', limit: 50 });
  const autoQueued = pending.find((a) => a.approvalType === 'semantic_cache_enforce' && a.targetId === policy.id);
  if (autoQueued) {
    console.log(`  pending: ${JSON.stringify(autoQueued)}`);
    console.log(
      '  This is the one step this script does NOT do: reviewing it requires a second privileged identity in the '
      + `console's Audit tab (${CONSOLE.audit}). Until reviewed, semantic-cache enforcement stays downgraded to `
      + "'suggest' - exact-cache enforcement above is unaffected, since it isn't gated by this queue.",
    );
  } else {
    console.log('  no matching pending entry found (it may already have been reviewed on a prior run of this example).');
  }

  const client = openaiStyleClient(key.accessToken, config.baseUrl);

  console.log('\nRepeating one exact prompt 5x for exact-cache evidence (enforced immediately, no approval needed)...');
  const exactPrompt = 'Summarize, in one sentence, why cloud costs increased for a customer running more Kubernetes pods this month.';
  const exactResults = [];
  for (let i = 0; i < 5; i += 1) {
    const result = await callOpenAIStyle(client, {
      model: MODELS.default, prompt: exactPrompt,
      headers: { 'x-cloptima-team': 'Platform AI', 'x-cloptima-app': appId, 'x-cloptima-environment': 'dev', 'x-cloptima-feature': 'exact_cache_probe' },
      label: `exact-cache-${i + 1}`,
    });
    exactResults.push(result);
    console.log(`  [${result.outcome}] exact-cache-${i + 1}`);
  }

  console.log('\nSending 3 semantically similar (not identical) prompts for semantic-cache evidence...');
  const semanticPrompts = [
    'In one sentence, explain why a customer running more Kubernetes pods saw higher cloud costs this month.',
    'Give a one-sentence explanation for increased cloud spend when a customer scales up their Kubernetes pod count.',
    'Why did this customer\'s cloud bill go up after running additional Kubernetes pods this month? One sentence.',
  ];
  const semanticResults = [];
  for (const [i, prompt] of semanticPrompts.entries()) {
    const result = await callOpenAIStyle(client, {
      model: MODELS.default, prompt,
      headers: { 'x-cloptima-team': 'Platform AI', 'x-cloptima-app': appId, 'x-cloptima-environment': 'dev', 'x-cloptima-feature': 'semantic_cache_probe' },
      label: `semantic-cache-${i + 1}`,
    });
    semanticResults.push(result);
    console.log(`  [${result.outcome}] semantic-cache-${i + 1}`);
  }

  console.log(
    '\nExpected: exact-cache hits show up immediately. Semantic-cache hits stay at \'suggest\' (logged but not '
    + 'served from cache) until the auto-queued approval above is reviewed - re-run this example after approving it '
    + 'in the console to see semantic-cache enforcement actually take effect.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - shows both the pending semantic_cache_enforce approval and the per-call cache hit/miss trail; Policies tab (${CONSOLE.policies}) shows the policy's cache config.`);
  console.log(JSON.stringify({ exactResults, semanticResults }, null, 2));
}

main().catch((err) => {
  console.error('semantic-cache-enforce failed:', err);
  process.exitCode = 1;
});
