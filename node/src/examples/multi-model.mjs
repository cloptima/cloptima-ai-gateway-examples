// One policy allowlisting several Vertex AI Gemini model variants (default
// flash, a cheaper flash-lite, and a higher-capability pro), mints a key,
// and calls each once - the "one policy, several models, compare cost and
// latency" story. These examples are built with Gemini models; bring your
// own credentials for other providers/models via the byok example.
//
// A model here can fail for two very different reasons, and this script
// reports which one happened rather than treating any non-200 as the same
// kind of failure:
//   - policy/model block (403)  -> the model isn't allowed by this policy
//   - missing pricing (402/403) -> the model is allowed, but the gateway's
//     pricing catalog doesn't have a cost entry for it yet, so a spend-
//     limited path fails closed. That's a pricing-catalog gap, not a sign
//     the model itself is unsupported.
//
// Run standalone:
//   node src/examples/multi-model.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS, OTHER_GEMINI_MODELS } from '../lib/models.mjs';

async function main() {
  const suffix = runSuffix();
  const appId = `multi-model-${suffix}`;
  const models = [MODELS.default, ...Object.values(OTHER_GEMINI_MODELS)];

  console.log(`Creating policy allowlisting ${models.length} Vertex AI Gemini model variants...`);
  const policy = await createPolicy({
    name: `multi-model-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: models,
  });
  console.log(`  policy ${policy.name} -> ${policy.id}`);

  const key = await createVirtualKey({ name: `vk-multi-model-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Calling each model once...\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const results = [];
  for (const model of models) {
    const result = await callOpenAIStyle(client, {
      model,
      prompt: 'In one short sentence, name the model you are.',
      headers: { 'x-cloptima-team': 'Platform AI', 'x-cloptima-app': appId, 'x-cloptima-environment': 'dev' },
      label: model,
    });
    results.push(result);
    const note = result.outcome === 'allowed'
      ? `text="${(result.text || '').slice(0, 80)}"`
      : `status=${result.status} reason=${JSON.stringify(result.reason).slice(0, 200)}`;
    console.log(`  [${result.outcome}] ${model} - ${note}`);
  }

  console.log(
    '\nIf any model above came back blocked with a pricing-related reason rather than a policy/model-allow ' +
    'reason, that means the model is real and allowlisted but the gateway pricing catalog needs a cost entry ' +
    'for it before spend-limited calls can succeed - check the pricing catalog/overlay, not the policy.',
  );
  console.log(`\nEvidence: Explorer tab (${CONSOLE.spend}) - filter by app "${appId}" to compare cost and latency across every model called above.`);
  console.log(JSON.stringify(results, null, 2));
}

main().catch((err) => {
  console.error('multi-model failed:', err);
  process.exitCode = 1;
});
