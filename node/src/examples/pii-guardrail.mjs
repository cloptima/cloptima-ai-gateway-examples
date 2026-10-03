// Uses a guardrail profile with an editable format rule for a fictional SSN.
// Run standalone: node src/examples/pii-guardrail.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createGuardrailProfile, createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { confirmBlocked } from '../lib/confirm.mjs';
import { MODELS } from '../lib/models.mjs';

async function main() {
  const suffix = runSuffix();
  const appId = `pii-guardrail-${suffix}`;
  const profile = await createGuardrailProfile({
    name: `pii-guardrail-${suffix}`,
    description: 'Redact or block credentials and configured personal-data formats',
    definition: {
      input: {
        action: 'block',
        detectors: { secret: {} },
        custom_rules: [{ id: 'us_ssn', match: { regex: '\\b\\d{3}-\\d{2}-\\d{4}\\b' } }],
      },
      output: { action: 'observe', detectors: { secret: {} } },
    },
  });
  const policy = await createPolicy({
    name: `pii-guardrail-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast', failMode: 'fail_closed',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    guardrailProfileId: profile.id,
  });
  const key = await createVirtualKey({
    name: `vk-pii-guardrail-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev',
  });
  await createBinding({
    policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev',
    priority: 10, acknowledgeOverlap: true,
  });

  const result = await callOpenAIStyle(openaiStyleClient(key.accessToken, config.baseUrl), {
    model: MODELS.default,
    prompt: 'This fictional QA record contains SSN 123-45-6789. Summarize it.',
    label: 'pii-format-rule-probe',
  });
  console.log(`[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  confirmBlocked(result, 'profile custom rule for a US SSN', { status: 403 });
  console.log('\nConfirmed: the profile rule blocked the matching input before model egress.');
  console.log(`Profile: ${profile.id}; policy: ${policy.id}; review them in ${CONSOLE.policies} and ${CONSOLE.audit}`);
}

main().catch((err) => {
  console.error('pii-guardrail failed:', err);
  process.exitCode = 1;
});
