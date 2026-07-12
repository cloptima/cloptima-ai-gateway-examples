// Creates a policy with realistic agentic-loop limits and simulates an agent
// retrying/looping via escalating x-cloptima-loop-iteration/retry-index
// headers, showing which iterations succeed vs. get blocked.
// Run standalone:
//   node src/examples/agentic-runaway.mjs
import { randomUUID } from 'node:crypto';
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

// Illustrative, not a platform minimum. Bounds: 0-1,000 for both fields.
const MAX_RETRY_COUNT = 5;
const MAX_LOOP_ITERATIONS = 5;
const ITERATIONS_TO_SIMULATE = 8;

async function main() {
  const suffix = runSuffix();
  const appId = `agentic-runaway-${suffix}`;

  console.log(`Creating policy with maxRetryCount=${MAX_RETRY_COUNT}, maxLoopIterations=${MAX_LOOP_ITERATIONS}...`);
  const policy = await createPolicy({
    name: `agentic-runaway-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: [MODELS.default],
    maxRetryCount: MAX_RETRY_COUNT,
    maxLoopIterations: MAX_LOOP_ITERATIONS,
  });
  const key = await createVirtualKey({ name: `vk-agentic-runaway-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound. Simulating ${ITERATIONS_TO_SIMULATE} escalating loop iterations...\n`);

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const sessionId = randomUUID();
  const results = [];
  for (let i = 0; i < ITERATIONS_TO_SIMULATE; i += 1) {
    const result = await callOpenAIStyle(client, {
      model: MODELS.default,
      prompt: 'Simulated agent loop step. Reply with just "ok".',
      headers: {
        'x-cloptima-team': 'Platform AI',
        'x-cloptima-app': appId,
        'x-cloptima-environment': 'dev',
        'x-cloptima-agent-session-id': sessionId,
        'x-cloptima-loop-iteration': String(i),
        'x-cloptima-retry-index': String(i),
      },
      label: `loop-iteration-${i}`,
    });
    results.push(result);
    console.log(`  [${result.outcome}] loop-iteration-${i}`);
  }

  console.log(
    `\nExpected: iterations 0-${MAX_LOOP_ITERATIONS} allowed, iteration ${MAX_LOOP_ITERATIONS + 1} onward blocked ` +
    '("exceeds the active Cloptima agent limits") - this is what catches a genuinely runaway agent loop.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - filter by agent session "${sessionId}" for the blocked loop iterations.`);
  console.log(JSON.stringify(results, null, 2));
}

main().catch((err) => {
  console.error('agentic-runaway failed:', err);
  process.exitCode = 1;
});
