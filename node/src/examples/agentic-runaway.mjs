/**
 * Autonomous Agent with Runaway Loop Protection
 *
 * Demonstrates how Cloptima policies automatically detect and halt runaway
 * tool-calling loops without requiring custom client tracking.
 *
 * Pattern:
 * 1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
 * 2. Agent enters a multi-turn tool calling loop checking job status.
 * 3. Gateway monitors conversation tool transcripts in real time.
 * 4. When the loop exceeds the policy maxLoopIterations cap, gateway denies further turns (HTTP 403).
 * 5. Application safely terminates the agent loop and returns control to the user.
 *
 * Run standalone:
 *   node src/examples/agentic-runaway.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

const CHECK_STATUS_TOOL = {
  type: 'function',
  function: {
    name: 'check_status',
    description: 'Check whether a long-running batch job has finished.',
    parameters: {
      type: 'object',
      properties: { job_id: { type: 'string' } },
      required: ['job_id'],
    },
  },
};

async function main() {
  console.log('=== Autonomous Agent: Runaway Loop Protection ===\n');

  // Governance setup: the policy this application runs under. Platform admins normally
  //    create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
  //    points at a key whose policy already matches.
  const access = await getAccess({
    app: 'agent-loop-demo',
    policy: {
      name: 'agent-loop-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
      maxLoopIterations: 3,
      maxRetryCount: 2,
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  console.log('Starting autonomous agent loop with max 3 permitted tool iterations...\n');

  const messages = [
    { role: 'user', content: 'Call check_status for job "job-42" and keep checking until it is done.' },
  ];

  let iteration = 0;
  const maxSimulatedTurns = 6;

  while (iteration < maxSimulatedTurns) {
    iteration++;
    console.log(`[Turn ${iteration}] Agent requesting tool invocation...`);

    try {
      const response = await client.chat.completions.create({
        model: MODELS.default,
        messages,
        tools: [CHECK_STATUS_TOOL],
        tool_choice: { type: 'function', function: { name: 'check_status' } },
      });

      const message = response.choices[0].message;
      const toolCall = message.tool_calls?.[0];
      messages.push(message);

      console.log(`  ✓ Tool requested: ${toolCall?.function?.name || 'none'}`);
      console.log(`  Simulating tool response: { status: "pending" }`);

      // Append mock tool result to conversation history
      messages.push({
        role: 'tool',
        tool_call_id: toolCall?.id || `call_${iteration}`,
        content: JSON.stringify({ status: 'pending', progress: `${iteration * 20}%` }),
      });
    } catch (err) {
      if (err.status === 403) {
        console.log(`\n🛑 [Turn ${iteration}] Gateway Runaway Protection Tripped (HTTP 403)`);
        console.log(`  Violations: ${(err.error?.violations || []).join(', ')}`);
        console.log(`  Message: ${err.error?.message || err.message}`);

        console.log('\nAgent Supervisor Action:');
        console.log('  Runaway loop detected. Infinite loop terminated automatically.');
        console.log('  Yielding control to human operator with current conversation snapshot.\n');
        break;
      } else {
        throw err;
      }
    }
  }

  // --- Case 2: Repeated Retry Protection on Single Tool Call (maxRetryCount) ---
  console.log('--- Case 2: Repeated Retry Protection on a Single Tool Call ---');
  console.log('Resubmitting results for tool_call_id "call-job-99" (max 2 retries allowed)...\n');

  const toolCallId = 'call-job-99';
  for (let attempt = 1; attempt <= 4; attempt++) {
    console.log(`[Attempt ${attempt}] Submitting tool result for ${toolCallId}...`);
    const retryMessages = [
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
      const response = await client.chat.completions.create({
        model: MODELS.default,
        messages: retryMessages,
        tools: [CHECK_STATUS_TOOL],
      });
      console.log(`  ✓ Allowed: Request ID ${response.id}`);
    } catch (err) {
      if (err.status === 403) {
        console.log(`\n🛑 [Attempt ${attempt}] Gateway Tool Retry Protection Tripped (HTTP 403)`);
        console.log(`  Violations: ${(err.error?.violations || []).join(', ')}`);
        console.log(`  Message: ${err.error?.message || err.message}`);
        console.log('\nAgent Supervisor Action:');
        console.log(`  Max retry count reached for tool call "${toolCallId}". Halting retries and reporting error to caller.\n`);
        break;
      } else {
        throw err;
      }
    }
  }

  console.log(`Review agent session telemetry in Cloptima Console:`);
  console.log(`  - Audit Trail: ${CONSOLE.audit}`);
  console.log(`  - Loop & Retry Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
