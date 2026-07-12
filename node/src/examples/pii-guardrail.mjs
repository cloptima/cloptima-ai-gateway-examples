// Two-step scenario, deliberately not a hardcoded "here's some fake PII"
// string: a hardcoded test string invites the fair objection "of course your
// detector matches its own fixture." Instead:
//   1. Ask the model itself, through an unguarded key, to invent a short
//      fictional support ticket containing fake PII. Nobody wrote this text;
//      the model generates it live, moments before step 2.
//   2. Feed that freshly-generated text through a second key bound to a
//      PII/secret guardrail policy. The guardrail has to detect content it
//      has never seen before.
// Run standalone:
//   node src/examples/pii-guardrail.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

async function main() {
  const suffix = runSuffix();
  const generatorAppId = `pii-guardrail-generator-${suffix}`;
  const guardedAppId = `pii-guardrail-${suffix}`;

  console.log('Creating an unguarded policy (to generate the fixture) and a guardrail-enforced policy...');
  const generatorPolicy = await createPolicy({
    name: `pii-guardrail-generator-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
  });
  const guardedPolicy = await createPolicy({
    name: `pii-guardrail-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    guardrailDetectorsEnabled: ['pii', 'secret'],
    guardrailOutputAction: 'redact',
  });

  const generatorKey = await createVirtualKey({
    name: `vk-pii-generator-${suffix}`, teamId: 'Platform AI', appId: generatorAppId, environment: 'dev',
  });
  const guardedKey = await createVirtualKey({
    name: `vk-pii-guardrail-${suffix}`, teamId: 'Platform AI', appId: guardedAppId, environment: 'dev',
  });
  await createBinding({ policyId: generatorPolicy.id, teamId: 'Platform AI', appId: generatorAppId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  await createBinding({ policyId: guardedPolicy.id, teamId: 'Platform AI', appId: guardedAppId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log('Minted both keys, bound. Generating a fictional PII-bearing ticket live...\n');

  const generatorClient = openaiStyleClient(generatorKey.accessToken, config.baseUrl);
  const generation = await callOpenAIStyle(generatorClient, {
    model: MODELS.default,
    prompt: 'Generate a short, entirely fictional customer support ticket transcript for a QA test. '
      + 'Include a clearly fake SSN in XXX-XX-XXXX format, a fake 16-digit credit card number, a fake email '
      + 'address, and a fake phone number - all obviously placeholder values, never real. Output only the ticket text.',
    headers: { 'x-cloptima-team': 'Platform AI', 'x-cloptima-app': generatorAppId, 'x-cloptima-environment': 'dev' },
    label: 'generate-fixture',
  });
  const generatedText = generation.text || '';
  console.log(`Generated ticket (fed into the guardrail-enforced call below):\n  ${generatedText.replace(/\n/g, '\n  ')}\n`);

  const guardedClient = openaiStyleClient(guardedKey.accessToken, config.baseUrl);
  const guarded = await callOpenAIStyle(guardedClient, {
    model: MODELS.default,
    prompt: `A customer submitted this support ticket. Draft a one-sentence acknowledgement reply.\n\n${generatedText}`,
    headers: { 'x-cloptima-team': 'Platform AI', 'x-cloptima-app': guardedAppId, 'x-cloptima-environment': 'dev' },
    label: 'pii-guardrail-probe',
  });

  console.log(`[${guarded.outcome}] ${JSON.stringify(guarded, null, 2)}`);
  console.log(
    '\nExpected: blocked before provider egress (403, detector_pii) - prompt-side PII is denied, not silently ' +
    'admitted. guardrailOutputAction: redact applies to generated output, not an incoming sensitive prompt.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - the block record names the pii/secret detector that fired; Policies tab (${CONSOLE.policies}) shows the guardrailDetectorsEnabled config.`);
}

main().catch((err) => {
  console.error('pii-guardrail failed:', err);
  process.exitCode = 1;
});
