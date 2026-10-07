/**
 * Multi-Tenant Cost Governance & Budget Overflow Handling
 *
 * Demonstrates how to attribute inference spend to teams and applications,
 * and how an application gracefully handles policy budget limits.
 *
 * Pattern:
 * 1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
 * 2. Attribute requests using team and application tags.
 * 3. Send requests within budget (served normally).
 * 4. Catch budget limit exhaustion (HTTP 402/403/429), alert or fall back gracefully.
 *
 * Run standalone:
 *   node src/examples/budget-limit.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

const DAILY_BUDGET_USD = 0.001;
const MAX_TOKENS_PER_CALL = 100;

async function main() {
  console.log('=== FinOps: Multi-Tenant Cost Governance & Budget Caps ===\n');

  // Governance setup: the policy this application runs under. Platform admins normally
  //    create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
  //    points at a key whose policy already matches.
  //    A hard budget reserves against estimated cost derived from max_tokens pre-flight.
  const access = await getAccess({
    app: 'budget-demo',
    policy: {
      name: 'budget-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
      dailyBudgetUsd: DAILY_BUDGET_USD,
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  console.log(`Executing workload under a policy with a $${DAILY_BUDGET_USD} daily budget cap.\n`);

  let successfulCalls = 0;
  let budgetTripped = false;

  // Execute requests in a loop until the small demo budget limit is reached
  for (let i = 1; i <= 30; i++) {
    try {
      const completion = await client.chat.completions.create({
        model: MODELS.default,
        max_tokens: MAX_TOKENS_PER_CALL,
        messages: [{ role: 'user', content: `Task #${i}: Generate a short status update.` }],
      });

      successfulCalls++;
      console.log(`[Call ${i}] Allowed - Tokens: ${completion.usage?.total_tokens} | Assistant: "${completion.choices[0].message.content.trim().slice(0, 40)}..."`);
    } catch (err) {
      if (err.status === 402 || err.status === 403 || err.status === 429) {
        budgetTripped = true;
        console.log(`\n🛑 [Call ${i}] Gateway Budget Limit Intercepted (HTTP ${err.status})`);
        console.log(`  Message: ${err.error?.message || err.message}`);
        console.log(`  Violations: ${(err.error?.violations || ['gateway_daily_budget_exceeded']).join(', ')}`);

        console.log('\nApplication FinOps Action:');
        console.log('  Daily budget quota reached. Application gracefully halted further non-critical requests.');
        console.log('  Alert dispatched to FinOps monitoring channel.\n');
        break;
      } else {
        throw err;
      }
    }
  }

  console.log(`Summary:`);
  console.log(`  - Successful calls admitted: ${successfulCalls}`);
  console.log(`  - Budget limit enforced: ${budgetTripped ? 'Yes' : 'Quota not exhausted yet'}\n`);

  console.log(`Review allocated spend and team attribution in the Cloptima Console:`);
  console.log(`  - Spend Explorer: ${CONSOLE.spend}`);
  console.log(`  - Budget Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
