// Completes what exact-semantic-cache.mjs deliberately leaves at 'observe':
// semanticCacheMode: 'enforce' needs a per-(app, route, model-family) class
// approval (createLLMSemanticCacheClassApproval) on top of the policy flag,
// AND setting 'enforce' on the policy itself auto-queues a separate entry in
// the generic governance queue (LLMGatewayApproval, approvalType
// 'semantic_cache_enforce') that must be reviewed before enforcement actually
// activates - until then, effective behavior stays downgraded to 'suggest'.
// This script creates the policy with applyImmediately: true, so - since the
// ai:admin key already qualifies to review this itself - that entry is
// approved and enforcement is live immediately, with no separate review step.
// See ../../docs/CACHE_AND_POLICY.md.
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

  console.log('Creating policy with exact cache (enforce) and semantic cache (enforce), applyImmediately: true...');
  const policy = await createPolicy({
    name: `semantic-cache-enforce-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    promptRetentionMode: 'full',
    exactCacheEnabled: true, exactCacheMode: 'enforce',
    semanticCacheEnabled: true, semanticCacheMode: 'enforce',
    applyImmediately: true,
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
  const applied = await listLLMGatewayApprovals({ status: 'applied', limit: 50 });
  const autoApplied = applied.find((a) => a.approvalType === 'semantic_cache_enforce' && a.targetId === policy.id);
  if (autoApplied) {
    console.log(`  applied: ${JSON.stringify(autoApplied)}`);
    console.log(
      '  applyImmediately: true above meant this entry was approved and applied right away, instead of sitting '
      + `pending for a second identity to review in the console's Audit tab (${CONSOLE.audit}).`,
    );
  } else {
    console.log('  no matching applied entry found.');
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
    '\nExpected: both exact-cache and semantic-cache hits show up immediately - applyImmediately: true meant '
    + 'semantic-cache enforcement was live from the start, with no separate review step needed.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - shows the applied semantic_cache_enforce approval and the per-call cache hit/miss trail; Policies tab (${CONSOLE.policies}) shows the policy's cache config.`);
  console.log(JSON.stringify({ exactResults, semanticResults }, null, 2));
}

main().catch((err) => {
  console.error('semantic-cache-enforce failed:', err);
  process.exitCode = 1;
});
