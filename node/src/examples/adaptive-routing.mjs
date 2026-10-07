/**
 * Adaptive Routing: Tiered Model Optimization
 *
 * Demonstrates how Cloptima policies configure candidate model tiers
 * (cheap, balanced, strong) to dynamically evaluate routing options and optimize
 * cost-to-performance tradeoffs.
 *
 * Pattern:
 * 1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
 * 2. Send requests through the policy configured with candidate model tiers.
 * 3. Inspect routing metadata and recommendations in the Cloptima Console.
 *
 * Run standalone:
 *   node src/examples/adaptive-routing.mjs
 */
import { CONSOLE } from '../lib/config.mjs';
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';

const CANDIDATE_MODELS = {
  cheap: [MODELS.default],
  balanced: [MODELS.default],
  strong: [MODELS.premium],
};

async function main() {
  console.log('=== Adaptive Routing: Cost & Performance Optimization ===\n');

  // Governance setup: a policy with candidate model tiers for adaptive routing in observe mode.
  // Platform admins normally create it once in the Console, Terraform, or CI. Skipped when
  // CLOPTIMA_VIRTUAL_KEY points at a key whose policy already matches.
  const access = await getAccess({
    app: 'adaptive-routing-demo',
    policy: {
      name: 'adaptive-routing-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [...new Set(Object.values(CANDIDATE_MODELS).flat())],
      metadata: {
        routing: {
          adaptive: {
            mode: 'observe',
            route_risk_ceiling: 'low',
            candidate_set_version: 'v1',
            candidate_models: CANDIDATE_MODELS,
          },
        },
      },
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  // Application sends workloads across candidate tiers
  const tasks = [
    { label: 'Routine Data Extraction', prompt: 'Extract city and temperature from: "It is 22C in London today".' },
    { label: 'Complex Synthesis', prompt: 'Summarize the CAP theorem and its impact on distributed consensus in 2 sentences.' },
  ];

  for (const [i, task] of tasks.entries()) {
    console.log(`[Request ${i + 1}: ${task.label}]`);
    console.log(`Prompt: "${task.prompt}"`);

    try {
      const response = await client.chat.completions.create({
        model: MODELS.default,
        messages: [{ role: 'user', content: task.prompt }],
      });

      console.log(`Assistant: "${response.choices[0].message.content.trim()}"`);
      console.log(`Usage: ${response.usage?.total_tokens} tokens | Request ID: ${response.id}\n`);
    } catch (err) {
      console.error(`Request failed: ${err.message}\n`);
    }
  }

  console.log(`Review adaptive routing recommendations and candidates in the Cloptima Console:`);
  console.log(`  - Recommendations & Routing: ${CONSOLE.recommendations}`);
  console.log(`  - Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
