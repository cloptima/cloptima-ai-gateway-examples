// Creates policies with realistic agentic-loop and retry limits and drives
// real tool-calling conversations against the gateway, showing which turns
// succeed vs. get blocked.
//
// Both limits are derived entirely from the tool-call transcript already
// present in each request body - the growing sequence of tool calls and
// results a normal tool-calling client already sends for the model to have
// any memory of what it already tried. No client-declared session, step, or
// retry identifiers are involved anywhere below.
//
// Loop depth counts completed tool-result turns in the conversation so far.
// Retry count is scoped per tool_call_id, so retrying one specific call and
// starting a new, different call are counted independently.
//
// Run standalone:
//   node src/examples/agentic-runaway.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { MODELS } from '../lib/models.mjs';

// Illustrative, not a platform minimum. Bounds: 0-1,000 for both fields.
const MAX_LOOP_ITERATIONS = 3;
const MAX_RETRY_COUNT = 2;

const CHECK_STATUS_TOOL = {
  type: 'function',
  function: {
    name: 'check_status',
    description: 'Check whether a long-running job has finished.',
    parameters: {
      type: 'object',
      properties: { job_id: { type: 'string' } },
      required: ['job_id'],
    },
  },
};

function blockedOutcome(index, err) {
  const status = err?.status ?? err?.response?.status;
  const body = err?.error ?? err?.response?.data ?? err?.message;
  return { index, outcome: 'blocked', status, reason: body };
}

async function runLoopIterations(client, model, iterationsToSimulate) {
  // Forces a real tool call every turn and feeds back a synthetic "still
  // running" result, then asks again - a realistic runaway-loop pattern.
  // Each turn resends the whole conversation so far, including every prior
  // tool call and result, exactly like a normal tool-calling client would.
  const messages = [{ role: 'user', content: 'Call check_status for job "job-42" and keep checking until it is done.' }];
  const results = [];
  for (let i = 0; i < iterationsToSimulate; i += 1) {
    let response;
    try {
      response = await client.chat.completions.create({
        model,
        messages,
        tools: [CHECK_STATUS_TOOL],
        tool_choice: { type: 'function', function: { name: 'check_status' } },
      });
    } catch (err) {
      results.push(blockedOutcome(i, err));
      break;
    }
    const toolCall = response.choices[0].message.tool_calls[0];
    results.push({ index: i, outcome: 'allowed', requestId: response.id, toolCallId: toolCall.id });
    messages.push({
      role: 'assistant',
      tool_calls: [{
        id: toolCall.id,
        type: 'function',
        function: { name: toolCall.function.name, arguments: toolCall.function.arguments },
      }],
    });
    messages.push({ role: 'tool', tool_call_id: toolCall.id, content: 'still running, check again' });
  }
  return results;
}

async function runRetryIterations(client, model, toolCallId, iterationsToSimulate) {
  // Resubmits the SAME tool_call_id's result repeatedly - a client
  // retrying one specific call. Retry scope is per tool_call_id, so this is
  // independent of loop depth and of any other call id.
  const results = [];
  for (let i = 0; i < iterationsToSimulate; i += 1) {
    const messages = [
      { role: 'user', content: 'Call check_status for job "job-99".' },
      {
        role: 'assistant',
        tool_calls: [{
          id: toolCallId,
          type: 'function',
          function: { name: 'check_status', arguments: '{"job_id": "job-99"}' },
        }],
      },
      { role: 'tool', tool_call_id: toolCallId, content: 'still running, check again' },
    ];
    try {
      const response = await client.chat.completions.create({ model, messages, tools: [CHECK_STATUS_TOOL] });
      results.push({ index: i, outcome: 'allowed', requestId: response.id });
    } catch (err) {
      results.push(blockedOutcome(i, err));
    }
  }
  return results;
}

async function main() {
  const suffix = runSuffix();

  const loopAppId = `agentic-loop-${suffix}`;
  console.log(`Creating policy with maxLoopIterations=${MAX_LOOP_ITERATIONS}...`);
  const loopPolicy = await createPolicy({
    name: `agentic-loop-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: [MODELS.default],
    maxLoopIterations: MAX_LOOP_ITERATIONS,
  });
  const loopKey = await createVirtualKey({ name: `vk-agentic-loop-${suffix}`, teamId: 'Platform AI', appId: loopAppId, environment: 'dev' });
  await createBinding({ policyId: loopPolicy.id, teamId: 'Platform AI', appId: loopAppId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${loopKey.id}, bound.\n`);

  const loopClient = openaiStyleClient(loopKey.accessToken, config.baseUrl);
  const loopIterationsToSimulate = MAX_LOOP_ITERATIONS + 2;
  console.log(`Driving a real tool-calling loop for ${loopIterationsToSimulate} turns...\n`);
  const loopResults = await runLoopIterations(loopClient, MODELS.default, loopIterationsToSimulate);
  for (const r of loopResults) {
    console.log(`  [${r.outcome}] turn ${r.index}`);
  }
  console.log(
    `\nExpected: turns 0-${MAX_LOOP_ITERATIONS} allowed, turn ${MAX_LOOP_ITERATIONS + 1} onward blocked ` +
    '("exceeds the active Cloptima agent limits") - counted from the tool-call turns already present in the ' +
    'conversation, not any client-supplied count.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - filter by app "${loopAppId}" for the blocked turn.`);
  console.log(JSON.stringify(loopResults, null, 2));

  const retryAppId = `agentic-retry-${suffix}`;
  console.log(`\nCreating policy with maxRetryCount=${MAX_RETRY_COUNT}...`);
  const retryPolicy = await createPolicy({
    name: `agentic-retry-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: [MODELS.default],
    maxRetryCount: MAX_RETRY_COUNT,
  });
  const retryKey = await createVirtualKey({ name: `vk-agentic-retry-${suffix}`, teamId: 'Platform AI', appId: retryAppId, environment: 'dev' });
  await createBinding({ policyId: retryPolicy.id, teamId: 'Platform AI', appId: retryAppId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${retryKey.id}, bound.\n`);

  const retryClient = openaiStyleClient(retryKey.accessToken, config.baseUrl);
  const retryIterationsToSimulate = MAX_RETRY_COUNT + 2;
  console.log(`Resubmitting the same tool call ${retryIterationsToSimulate} times...\n`);
  const retryResults = await runRetryIterations(retryClient, MODELS.default, 'call-job-99', retryIterationsToSimulate);
  for (const r of retryResults) {
    console.log(`  [${r.outcome}] attempt ${r.index}`);
  }
  console.log(
    `\nExpected: attempts 0-${MAX_RETRY_COUNT} allowed, attempt ${MAX_RETRY_COUNT + 1} onward blocked - counted ` +
    'per tool_call_id, so a different call id gets its own independent count.',
  );
  const otherCallResult = (await runRetryIterations(retryClient, MODELS.default, 'call-job-100', 1))[0];
  console.log(`  [${otherCallResult.outcome}] a different tool_call_id, first attempt`);
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - filter by app "${retryAppId}" for the blocked attempt.`);
  console.log(JSON.stringify([...retryResults, otherCallResult], null, 2));
}

main().catch((err) => {
  console.error('agentic-runaway failed:', err);
  process.exitCode = 1;
});
