/**
 * Guardrail Cost Governance: Managed Provider Scan Cost Capping
 *
 * Demonstrates how to configure a per-request cost cap on provider-backed guardrail
 * scans (e.g. Google Model Armor) to protect against unexpected security scanning costs.
 *
 * Prerequisite:
 * - Requires available Cloptima managed credits because external provider scans are billable.
 *
 * Run standalone:
 *   node src/examples/guardrail-cost-governance.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { CONSOLE } from '../lib/config.mjs';
import { MODELS } from '../lib/models.mjs';

const MAX_COST_PER_REQUEST_CENTS = 1;

async function main() {
  console.log('=== Guardrail Cost Governance: Per-Request Scan Cap ===\n');
  console.log('Prerequisite: The account must have managed credits available for billable guardrail scans.\n');

  // Governance setup: a guardrail profile with a managed Model Armor scan and a per-request cost cap,
  // attached to the policy this application runs under. Platform admins normally create these once
  // in the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at a key whose policy
  // already matches.
  console.log(`Configuring guardrail profile with Google Model Armor and a ${MAX_COST_PER_REQUEST_CENTS}¢ cap...`);
  const access = await getAccess({
    app: 'guardrail-cost-demo',
    guardrailProfile: {
      name: 'guardrail-cost-profile',
      description: 'Managed Model Armor scan with a per-request cost cap',
      definition: {
        input: { action: 'observe', detectors: { secret: {} } },
        output: { action: 'observe', detectors: { secret: {} } },
        provider_integration: {
          kind: 'google_model_armor',
          credential_source: 'cloptima_managed',
          scan_directions: 'input',
        },
        cost: {
          mode: 'enforce',
          max_cost_per_request_cents: MAX_COST_PER_REQUEST_CENTS,
          exceeded_action: 'block',
        },
      },
    },
    policy: {
      name: 'guardrail-cost-policy',
      mode: 'enforce',
      budgetMode: 'hard_fast',
      failMode: 'fail_closed',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  console.log('Sending user prompt through guarded route...');
  try {
    const response = await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: 'Confirm this request passed safety scan within cost budget.' }],
    });

    console.log(`Assistant: "${response.choices[0].message.content.trim()}"`);
    console.log(`Scan outcome: Admitted and served within the ${MAX_COST_PER_REQUEST_CENTS}¢ budget cap.`);
  } catch (err) {
    if (err.status === 403) {
      console.log(`🛑 Scan Cost Exceeded Cap (HTTP 403): ${err.message}`);
    } else {
      console.error(`Request error: ${err.message}`);
    }
  }

  console.log(`\nReview guardrail scan ledger and policies in Cloptima Console:`);
  console.log(`  - Guardrail Scan Ledger: ${CONSOLE.audit}`);
  console.log(`  - Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
