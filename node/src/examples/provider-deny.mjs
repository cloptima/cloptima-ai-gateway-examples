/**
 * Provider Restriction & Data Residency Enforcement
 *
 * Demonstrates how enterprise policies enforce approved provider boundaries
 * (e.g. Vertex AI only for data residency/compliance), and how an application
 * catches and recovers from unauthorized provider requests.
 *
 * Pattern:
 * 1. Policy enforces allowedProviders: ['vertex_ai'].
 * 2. Application attempts calling an unauthorized provider (e.g. openai/gpt-4o).
 * 3. Gateway blocks before provider egress (HTTP 403).
 * 4. Application catches the block and falls back to an authorized model.
 *
 * Run standalone:
 *   node src/examples/provider-deny.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { CONSOLE } from '../lib/config.mjs';
import { MODELS } from '../lib/models.mjs';

async function main() {
  console.log('=== Enterprise Compliance: Provider Boundary Enforcement ===\n');

  // Governance setup: a compliance policy that allows only Vertex AI. Platform admins normally
  // create it once in the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at
  // a key whose policy already matches.
  const access = await getAccess({
    app: 'provider-boundary-demo',
    policy: {
      name: 'provider-boundary-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  console.log('Policy active: Only "vertex_ai" is permitted.\n');

  // Case 1: Application requests an unauthorized provider
  console.log('--- Step 1: Requesting Unauthorized Provider (openai/gpt-4o) ---');
  let fallbackNeeded = false;

  try {
    await client.chat.completions.create({
      model: 'openai/gpt-4o',
      messages: [{ role: 'user', content: 'Process confidential compliance record.' }],
    });
    console.log('Assistant: (Processed unexpectedly)\n');
  } catch (err) {
    if (err.status === 403) {
      console.log('🛡️ Gateway Compliance Block (HTTP 403)');
      console.log(`  Message: ${err.error?.message || err.message}`);
      console.log(`  Violations: ${(err.error?.violations || []).join(', ')}`);
      console.log('\nApplication Recovery:');
      console.log('  Non-compliant provider request intercepted. Automatically routing to authorized Vertex AI model...\n');
      fallbackNeeded = true;
    } else {
      throw err;
    }
  }

  // Case 2: Recovery via approved compliant model
  if (fallbackNeeded) {
    console.log(`--- Step 2: Fallback to Approved Model (${MODELS.default}) ---`);
    try {
      const recoveryResponse = await client.chat.completions.create({
        model: MODELS.default,
        messages: [{ role: 'user', content: 'Process confidential compliance record.' }],
      });
      console.log(`Assistant: "${recoveryResponse.choices[0].message.content.trim()}"`);
      console.log('✓ Workload successfully fulfilled on compliant infrastructure.\n');
    } catch (err) {
      console.error('Recovery failed:', err.message);
    }
  }

  console.log(`Review provider restriction audit logs in Cloptima Console:`);
  console.log(`  - Audit Trail: ${CONSOLE.audit}`);
  console.log(`  - Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
