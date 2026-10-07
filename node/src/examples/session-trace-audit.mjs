/**
 * Autonomous Enterprise Agent: Cryptographic Session Ledger & Tool I/O Auditing
 *
 * In enterprise agentic systems, autonomous agents often execute sensitive operations:
 * - Querying order and customer records (check_order_status)
 * - Authorizing financial transactions (issue_refund)
 * - Transmitting customer records to third-party endpoints (export_customer_data)
 *
 * For compliance, security, and forensics, organizations must audit exact tool parameters
 * without storing sensitive conversational user text.
 *
 * Cloptima provides:
 * 1. Selective Prompt Retention (promptRetentionMode: 'tool_io'): Tool calls, arguments,
 *    and results are captured verbatim for compliance, while user chat text is omitted.
 * 2. Cryptographic Session Ledger: Every step in an agent session is correlated via
 *    'x-cloptima-agent-session-id' and anchored with a SHA-256 integrity hash (traceSha256).
 */
import { openaiClient } from '../lib/client.mjs';
import { provisionApp } from '../lib/access.mjs';
import { runSuffix } from '../lib/config.mjs';
import {
  getLlmAgentSession,
  getLlmAgentSessionRecords,
} from '../lib/gatewayAdmin.mjs';
import { MODELS } from '../lib/models.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'check_order_status',
      description: 'Look up order fulfillment and delivery status by order ID.',
      parameters: {
        type: 'object',
        properties: {
          order_id: { type: 'string', description: 'The unique order identifier (e.g. ORD-98241).' },
        },
        required: ['order_id'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'issue_refund',
      description: 'Authorize and issue a financial refund for an order.',
      parameters: {
        type: 'object',
        properties: {
          order_id: { type: 'string', description: 'The order identifier.' },
          amount_usd: { type: 'number', description: 'Refund amount in USD.' },
          reason: { type: 'string', description: 'Reason for refund.' },
        },
        required: ['order_id', 'amount_usd', 'reason'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'export_customer_data',
      description: 'Export customer details and order records to an external compliance audit endpoint.',
      parameters: {
        type: 'object',
        properties: {
          customer_id: { type: 'string', description: 'The customer identifier.' },
          destination_url: { type: 'string', description: 'External webhook URL.' },
          fields: {
            type: 'array',
            items: { type: 'string' },
            description: 'Customer record fields to include in export.',
          },
        },
        required: ['customer_id', 'destination_url', 'fields'],
      },
    },
  },
];

async function main() {
  const suffix = runSuffix();
  const agentSessionId = `session-${suffix}`;
  const orderId = `ORD-${Math.floor(10000 + Math.random() * 90000)}`;
  const customerId = `CUST-${Math.floor(1000 + Math.random() * 9000)}`;
  const externalWebhookUrl = 'https://partner-audit.example.com/ingest';

  console.log(`Connecting to Cloptima Gateway with session correlation (${agentSessionId})...`);
  // Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy,
  // key, and binding once in the Console, Terraform, or CI.
  const { virtualKey } = await provisionApp({
    app: 'support-agent-demo',
    policy: {
      name: 'session-trace-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
      promptRetentionMode: 'tool_io', // capture tool calls and results, omit user chat text
    },
  });

  // Application code: every call in the agent session carries the same session ID header.
  const client = openaiClient(virtualKey, {
    defaultHeaders: { 'x-cloptima-agent-session-id': agentSessionId },
  });

  const messages = [
    {
      role: 'user',
      content: `Check delivery status for order ${orderId} (customer ${customerId}). If delivered, export the customer delivery confirmation to partner audit sink ${externalWebhookUrl}.`,
    },
  ];

  let turnCount = 0;

  // Turn 1: Model decides to check order status
  console.log('\n[Agent Turn 1] User issues multi-step order inspection request...');
  const response1 = await client.chat.completions.create({
    model: MODELS.default,
    messages,
    tools: TOOLS,
    tool_choice: { type: 'function', function: { name: 'check_order_status' } },
  });
  turnCount += 1;

  const toolCall1 = response1.choices[0]?.message?.tool_calls?.[0];
  if (!toolCall1) {
    throw new Error('Expected agent to invoke check_order_status tool.');
  }
  console.log(`Model invoked tool: ${toolCall1.function.name}(${toolCall1.function.arguments})`);

  messages.push(response1.choices[0].message);
  messages.push({
    role: 'tool',
    tool_call_id: toolCall1.id,
    content: JSON.stringify({
      order_id: orderId,
      customer_id: customerId,
      status: 'delivered',
      carrier: 'FedEx',
      delivered_at: '2026-09-14T18:32:00Z',
    }),
  });

  // Turn 2: Feed tool output to model; model decides to export data
  console.log('\n[Agent Turn 2] Feeding delivery status to agent; agent executes conditional action...');
  const response2 = await client.chat.completions.create({
    model: MODELS.default,
    messages,
    tools: TOOLS,
  });
  turnCount += 1;

  const toolCall2 = response2.choices[0]?.message?.tool_calls?.[0];
  if (toolCall2) {
    console.log(`Model invoked tool: ${toolCall2.function.name}(${toolCall2.function.arguments})`);
    console.log('-> Destination URL and exported fields captured in Cloptima tool audit trail.');

    messages.push(response2.choices[0].message);
    messages.push({
      role: 'tool',
      tool_call_id: toolCall2.id,
      content: JSON.stringify({
        status: 'success',
        exported_records: 1,
        destination_acknowledged: true,
        transaction_id: `TXN-${Math.floor(100000 + Math.random() * 900000)}`,
      }),
    });

    // Turn 3: Complete interaction
    console.log('\n[Agent Turn 3] Finalizing customer response...');
    const response3 = await client.chat.completions.create({
      model: MODELS.default,
      messages,
      tools: TOOLS,
    });
    turnCount += 1;
    console.log(`Agent Final Answer: "${response3.choices[0]?.message?.content?.trim()}"`);
  } else {
    console.log(`Agent Final Answer: "${response2.choices[0]?.message?.content?.trim()}"`);
  }

  // Compliance Audit & Cryptographic Verification
  console.log('\n--- Compliance Audit: Querying Cryptographic Session Ledger ---');
  let session = null;
  for (let attempt = 0; attempt < 6; attempt += 1) {
    if (attempt > 0) await sleep(1000);
    try {
      session = await getLlmAgentSession({ sessionId: agentSessionId });
      const steps = session?.steps || [];
      if (steps.length >= turnCount && steps.every((s) => s.traceSha256)) break;
    } catch {
      // Retry for ledger entry to flush
    }
  }

  const steps = session?.steps || [];
  console.log(`Session Correlated: ${session?.agentSessionId || agentSessionId} (${steps.length} steps recorded)`);
  for (const [index, step] of steps.entries()) {
    console.log(`\n  Step ${index + 1}:`);
    console.log(`    Request ID:    ${step.requestId}`);
    console.log(`    Provider/Model: ${step.provider} / ${step.model}`);
    console.log(`    Status:        ${step.status} (${step.inputTokens} in / ${step.outputTokens} out, cost: $${step.costUsd})`);
    console.log(`    Invoked Tool:  ${step.responseToolNames?.join(', ') || 'none'}`);
    console.log(`    Trace SHA-256: ${step.traceSha256 || 'none'}`);
  }

  const recordsData = await getLlmAgentSessionRecords({ sessionId: agentSessionId });
  const records = recordsData?.records || [];
  console.log(`\nVerified tamper-evident records: ${records.length} tool trace items anchored to ledger.`);
  for (const rec of records) {
    console.log(`  Request ${rec.requestId} -> verification: ${rec.verification}`);
  }
}

main().catch((err) => {
  console.error('session-trace-audit execution failed:', err.message);
  process.exitCode = 1;
});
