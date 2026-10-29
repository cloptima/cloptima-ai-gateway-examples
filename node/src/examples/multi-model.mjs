/**
 * Multi-Model Gateway: Switching and Comparing Models
 *
 * Demonstrates how a single Cloptima virtual key and standard OpenAI client
 * can seamlessly dispatch across different model tiers under one unified policy.
 *
 * Pattern:
 * 1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
 * 2. Dispatch identical prompts to multiple model tiers (e.g. Flash Lite vs Flash).
 * 3. Compare latency, token consumption, and response quality.
 *
 * Run standalone:
 *   node src/examples/multi-model.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

async function main() {
  console.log('=== Multi-Model Gateway: Unified Model Comparison ===\n');

  // Governance setup: the policy this application runs under. Platform admins normally
  //    create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
  //    points at a key whose policy already matches.
  const access = await getAccess({
    app: 'multi-model-demo',
    policy: {
      name: 'multi-model-policy',
      mode: 'enforce',
      budget_mode: 'hard',
      allowed_providers: ['vertex_ai'],
      allowed_models: [MODELS.default, MODELS.premium], // both models are allowlisted under one policy
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  const modelsToCompare = [MODELS.default, MODELS.premium];

  const testPrompt = 'Explain the difference between vertical and horizontal autoscaling in 2 sentences.';
  console.log(`Evaluating prompt across ${modelsToCompare.length} models:\n"${testPrompt}"\n`);

  for (const model of modelsToCompare) {
    console.log(`--- Model: ${model} ---`);
    const start = Date.now();

    try {
      const completion = await client.chat.completions.create({
        model,
        messages: [{ role: 'user', content: testPrompt }],
      });

      const elapsedMs = Date.now() - start;
      const content = completion.choices[0]?.message?.content?.trim() || '';
      const usage = completion.usage;

      console.log(`Assistant: ${content}`);
      console.log(`Metrics: ${elapsedMs}ms latency | ${usage?.total_tokens} tokens (${usage?.prompt_tokens} in / ${usage?.completion_tokens} out)\n`);
    } catch (err) {
      console.log(`Error calling ${model}: ${err.message}\n`);
    }
  }

  console.log(`Compare aggregate cost and latency per model in the Cloptima Console:`);
  console.log(`  - Explorer: ${CONSOLE.spend}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
