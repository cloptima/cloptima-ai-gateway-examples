/**
 * Summarization Service with Output Token Boundaries
 *
 * Demonstrates how Cloptima policies prevent runaway output generation
 * and protect against compute cost overruns pre-flight.
 *
 * Pattern:
 * 1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
 * 2. Case 1: Concise summary within token bounds -> admitted and generated.
 * 3. Case 2: Oversized generation violating maxOutputTokens cap -> blocked pre-flight.
 * 4. Application catches the token boundary error and informs the caller.
 *
 * Run standalone:
 *   node src/examples/token-limit.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

async function main() {
  console.log('=== Summarization Service: Output Token Boundaries ===\n');

  // Governance setup: the policy this application runs under. Platform admins normally
  //    create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
  //    points at a key whose policy already matches.
  const access = await getAccess({
    app: 'token-limit-demo',
    policy: {
      name: 'token-limit-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
      maxOutputTokens: 100, // the minimum allowed value is 64
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  // 2. Case 1: Concise request within bounds
  console.log('--- Case 1: Concise Summary (Within Token Cap) ---');
  try {
    const response = await client.chat.completions.create({
      model: MODELS.default,
      max_tokens: 30,
      messages: [{ role: 'user', content: 'Summarize the concept of API gateways in 10 words.' }],
    });
    console.log(`Assistant: "${response.choices[0].message.content.trim()}"`);
    console.log(`Tokens used: ${response.usage?.completion_tokens}\n`);
  } catch (err) {
    console.error('Unexpected error on valid token call:', err.message);
  }

  // 3. Case 2: Excessive generation exceeding policy limit
  console.log('--- Case 2: Unbounded Generation (Exceeding Policy Limit) ---');
  const oversizedPrompt = 'Write a comprehensive 500-word analysis on distributed microservice architectures.';
  console.log(`User: "${oversizedPrompt}"`);

  try {
    await client.chat.completions.create({
      model: MODELS.default,
      // Requesting 500 tokens exceeds the policy's maxOutputTokens cap of 100
      max_tokens: 500,
      messages: [{ role: 'user', content: oversizedPrompt }],
    });
    console.log('Assistant: (Generated unexpectedly)\n');
  } catch (err) {
    if (err.status === 403) {
      console.log('🛑 [Pre-flight Token Block: HTTP 403]');
      console.log(`  Message: ${err.error?.message || err.message}`);
      console.log(`  Violations: ${(err.error?.violations || []).join(', ')}`);

      console.log('\nApplication Fallback Action:');
      console.log('  Request rejected pre-flight before incurring compute costs.');
      console.log('  Notice to client: "Please request a concise summary (under 100 tokens) or adjust your policy quota."\n');
    } else {
      throw err;
    }
  }

  console.log(`Review token limit policies in the Cloptima Console:`);
  console.log(`  - Audit Trail: ${CONSOLE.audit}`);
  console.log(`  - Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
