/**
 * FinOps Attribution: Mandatory Team & App Metadata
 *
 * Demonstrates how enterprise organizations enforce chargeback and cost allocation
 * by requiring attribution headers on all managed inference requests.
 *
 * Pattern:
 * 1. Initialize client using an unscoped virtual key (no team or app baked in).
 * 2. Case 1: Call without attribution metadata -> Gateway refuses with HTTP 400.
 * 3. Case 2: Call with proper x-cloptima-team and x-cloptima-app headers -> Admitted.
 *
 * Auth: CLOPTIMA_AI_ADMIN_KEY creates the policy and an unscoped key. CLOPTIMA_VIRTUAL_KEY must be
 * an unscoped key bound to a policy that requires team_id, app_id, and environment; a key with team
 * and app baked in supplies its own attribution, so Case 1 would not be refused.
 *
 * Run standalone:
 *   node src/examples/metadata-deny.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { runSuffix, CONSOLE, config } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { MODELS } from '../lib/models.mjs';

async function main() {
  console.log('=== FinOps Attribution: Enforcing Team & Application Tags ===\n');

  const suffix = runSuffix();
  let virtualKey;

  if (config.virtualKey) {
    console.log('Using CLOPTIMA_VIRTUAL_KEY. It should be an unscoped key bound to a policy requiring attribution metadata.\n');
    virtualKey = config.virtualKey;
  } else if (config.aiAdminKey) {
    console.log('Configuring policy requiring attribution metadata...');
    const policy = await createPolicy({
      name: `attribution-policy-${suffix}`,
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
      metadata: { required_metadata_keys: ['team_id', 'app_id', 'environment'] },
    });

    // Key created without baked-in team/app to demonstrate header-driven attribution
    const key = await createVirtualKey({ name: `vk-attribution-${suffix}` });

    await createBinding({
      policyId: policy.id,
      principalId: key.id,
      actorType: 'service',
      priority: 5,
      acknowledgeOverlap: true,
    });
    virtualKey = key.accessToken;
  } else {
    throw new Error(
      'Set CLOPTIMA_VIRTUAL_KEY to use an existing key, or CLOPTIMA_AI_ADMIN_KEY to let this example create its own policy and key (see .env.example).'
    );
  }

  const client = openaiClient(virtualKey);

  // Case 1: Calling without required attribution headers
  console.log('--- Case 1: Unattributed Request (Missing Headers) ---');
  try {
    await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: 'Execute unallocated query.' }],
    });
    console.log('Assistant: (Admitted unexpectedly)\n');
  } catch (err) {
    if (err.status === 400 || err.status === 403) {
      console.log('🛑 Gateway Attribution Enforcement (HTTP 400)');
      console.log(`  Message: ${err.error?.message || err.message}`);
      console.log('\nApplication Action:');
      console.log('  Request rejected because team and application cost centers were not provided.\n');
    } else {
      throw err;
    }
  }

  // Case 2: Supplying attribution headers
  console.log('--- Case 2: Attributed Request (With Cost Center Headers) ---');
  const teamId = 'Payment-Services';
  const appId = 'checkout-fraud-detection';
  console.log(`Injecting headers: x-cloptima-team="${teamId}", x-cloptima-app="${appId}"`);

  try {
    const response = await client.chat.completions.create(
      {
        model: MODELS.default,
        messages: [{ role: 'user', content: 'Explain fraud detection scoring briefly.' }],
      },
      {
        headers: {
          'x-cloptima-team': teamId,
          'x-cloptima-app': appId,
          'x-cloptima-environment': 'production',
        },
      },
    );

    console.log(`Assistant: "${response.choices[0].message.content.trim()}"`);
    console.log(`✓ Request admitted and attributed to team "${teamId}" and app "${appId}".\n`);
  } catch (err) {
    console.error('Attributed call failed:', err.message);
  }

  console.log(`Review attributed spend in the Cloptima Console:`);
  console.log(`  - Spend Explorer: ${CONSOLE.spend}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
