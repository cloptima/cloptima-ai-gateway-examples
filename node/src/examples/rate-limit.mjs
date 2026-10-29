/**
 * Resilient Batch Worker: Rate Limit Handling & Backoff
 *
 * Demonstrates how client applications handle rate limits (HTTP 429) enforced
 * by Cloptima policies using standard retry and exponential backoff patterns.
 *
 * Pattern:
 * 1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
 * 2. Process a series of tasks.
 * 3. When rate limits are tripped (HTTP 429), catch the error, back off, and retry.
 *
 * Run standalone:
 *   node src/examples/rate-limit.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function executeWithRetry(client, taskPrompt, maxRetries = 3) {
  let attempt = 0;
  let delayMs = 1000;

  while (attempt <= maxRetries) {
    try {
      const completion = await client.chat.completions.create({
        model: MODELS.default,
        max_tokens: 30,
        messages: [{ role: 'user', content: taskPrompt }],
      });
      return { status: 200, content: completion.choices[0]?.message?.content?.trim() };
    } catch (err) {
      if (err.status === 429 && attempt < maxRetries) {
        attempt++;
        console.log(`  ⚠️ Rate limit reached (HTTP 429). Retrying in ${delayMs}ms (attempt ${attempt}/${maxRetries})...`);
        await sleep(delayMs);
        delayMs *= 2; // exponential backoff
      } else {
        throw err;
      }
    }
  }
}

async function main() {
  console.log('=== Resilient Application: Rate Limiting & Backoff ===\n');

  // Governance setup: the policy this application runs under. Platform admins normally
  //    create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
  //    points at a key whose policy already matches.
  const access = await getAccess({
    app: 'rate-limit-demo',
    policy: {
      name: 'rate-limit-policy',
      mode: 'enforce',
      budget_mode: 'hard',
      allowed_providers: ['vertex_ai'],
      allowed_models: [MODELS.default],
      request_rate_limit_per_minute: 3,
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  console.log('Sending requests through rate-limited policy...\n');

  const tasks = [
    'Translate "Hello" to French.',
    'Translate "Thank you" to Spanish.',
    'Translate "Good morning" to German.',
    'Translate "Goodbye" to Italian.',
    'Translate "Welcome" to Portuguese.',
  ];

  for (const [i, task] of tasks.entries()) {
    console.log(`[Task ${i + 1}] Submitting: "${task}"`);
    try {
      const result = await executeWithRetry(client, task);
      console.log(`  ✓ Completed: "${result.content}"\n`);
    } catch (err) {
      console.log(`  ❌ Task failed permanently: ${err.message}\n`);
    }
  }

  console.log(`Review rate limit events and policy audit in the Cloptima Console:`);
  console.log(`  - Audit Trail: ${CONSOLE.audit}`);
  console.log(`  - Rate Limit Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
