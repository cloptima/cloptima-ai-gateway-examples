// Creates a policy requiring attribution metadata, but mints its virtual key
// deliberately WITHOUT team/app/environment and binds it by principalId
// instead - the only way to produce a genuine missing-attribution block, since
// a key with baked-in team/app/environment is trusted as an attribution
// fallback when headers are absent. Calling with zero headers on this
// deliberately unscoped key trips a more fundamental gate before the policy's
// own required-metadata check ever runs.
// Run standalone:
//   node src/examples/metadata-deny.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

async function main() {
  const suffix = runSuffix();

  console.log('Creating a policy that requires team_id/app_id/environment metadata...');
  const policy = await createPolicy({
    name: `metadata-deny-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    metadata: { required_metadata_keys: ['team_id', 'app_id', 'environment'] },
  });

  console.log('Minting a key with NO team/app/environment on purpose...');
  const key = await createVirtualKey({ name: `vk-metadata-deny-${suffix}` });

  console.log('Binding by the key\'s own principalId (not team/app/environment)...');
  // A principalId-only binding has no team/app/environment to distinguish its
  // scope, so it always overlaps every other binding in the org - acknowledging
  // that is required, not optional here.
  await createBinding({ policyId: policy.id, principalId: key.id, actorType: 'service', priority: 5, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Calling with zero attribution headers...\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const result = await callOpenAIStyle(client, {
    model: MODELS.default,
    prompt: 'This call should be denied - the key is deliberately unscoped and no attribution metadata is sent.',
    headers: {},
    label: 'metadata-deny-probe',
  });

  console.log(`[${result.outcome}] ${JSON.stringify(result, null, 2)}`);
  console.log(
    '\nExpected: 400 - "Managed AI requests require Cloptima team and app attribution" - a more basic gate ' +
    'than the policy engine\'s own required_metadata_keys check, but a genuine block either way.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - filter by key ${key.id} for the missing-attribution block record.`);
}

main().catch((err) => {
  console.error('metadata-deny failed:', err);
  process.exitCode = 1;
});
