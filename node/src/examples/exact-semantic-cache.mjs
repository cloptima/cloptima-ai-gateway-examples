// Creates a policy with exact cache enabled (enforce mode, full retention -
// required to actually replay cached responses, otherwise exact cache stores
// metadata-only would-hit entries) and semantic cache enabled (observe mode -
// enforce mode needs an additional per-app/content-class/model-family
// approval on top of the policy flag). Repeats one exact prompt for
// exact-cache evidence, then sends paraphrased variants for semantic-cache
// evidence. There is no client-side cache toggle - this is entirely
// policy-driven server-side; see ../../docs/CACHE_AND_POLICY.md.
// Run standalone:
//   node src/examples/exact-semantic-cache.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

async function main() {
  const suffix = runSuffix();
  const appId = `cache-demo-${suffix}`;

  console.log('Creating policy with exact cache (enforce, full retention) and semantic cache (observe)...');
  const policy = await createPolicy({
    name: `exact-semantic-cache-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    promptRetentionMode: 'full',
    exactCacheEnabled: true, exactCacheMode: 'enforce',
    semanticCacheEnabled: true, semanticCacheMode: 'observe',
  });
  const key = await createVirtualKey({ name: `vk-cache-demo-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound.\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);

  console.log('Repeating one exact prompt 5x for exact-cache evidence...');
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
    '\nCache hit/miss decisions show up in the console, not in this script\'s own output - compare latency and ' +
    'usage across the repeats above, then check the console for the authoritative hit/miss trail.',
  );
  console.log(`Evidence: Dashboard tab (${CONSOLE.dashboard}) shows realized cache savings; Explorer tab (${CONSOLE.spend}) shows per-request cached-token counts for the repeats above; Audit tab (${CONSOLE.audit}) has the authoritative hit/miss trail.`);
  console.log(JSON.stringify({ exactResults, semanticResults }, null, 2));
}

main().catch((err) => {
  console.error('exact-semantic-cache failed:', err);
  process.exitCode = 1;
});
