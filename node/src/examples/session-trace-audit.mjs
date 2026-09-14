// Configures tool I/O capture on an agentic policy, runs a multi-tool agentic
// workflow with session correlation, and reads back the cryptographic ledger
// audit trail and tool trace records.
//
// In enterprise agentic systems, agents are often given access to multiple tools:
// standard lookups (check_order_status), financial actions (issue_refund), and
// external data sinks (export_customer_data). Auditing tool invocations and their
// exact arguments is critical to detect unintended behavior, prompt injection,
// or rogue models transmitting customer data to unapproved external endpoints.
//
// Setting promptRetentionMode: 'tool_io' enables capturing tool calls, arguments,
// and results verbatim, while keeping conversational user text and system
// prompts uncollected to protect user privacy.
//
// Each step is anchored with a SHA-256 integrity hash (traceSha256) on the
// ledger at request time, creating a tamper-evident audit record.
//
// Run standalone:
//   node src/examples/session-trace-audit.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import {
  createPolicy,
  createVirtualKey,
  createBinding,
  getLlmAgentSession,
  getLlmAgentSessionRecords,
} from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { confirmAllowed } from '../lib/confirm.mjs';
import { MODELS } from '../lib/models.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// 1. Read-only order query tool
const CHECK_ORDER_TOOL = {
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
};

// 2. Financial transaction tool
const ISSUE_REFUND_TOOL = {
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
};

// 3. Sensitive external egress tool (capable of transmitting customer data to external endpoints)
const EXPORT_CUSTOMER_DATA_TOOL = {
  type: 'function',
  function: {
    name: 'export_customer_data',
    description: 'Export customer details, account records, and order history to an external data sink or webhook URL.',
    parameters: {
      type: 'object',
      properties: {
        customer_id: { type: 'string', description: 'The customer identifier.' },
        destination_url: { type: 'string', description: 'External HTTP endpoint or webhook URL to receive exported data.' },
        fields: {
          type: 'array',
          items: { type: 'string' },
          description: 'Customer record fields to include in export (e.g. email, shipping_address, payment_history).',
        },
      },
      required: ['customer_id', 'destination_url', 'fields'],
    },
  },
};

const TOOLS = [CHECK_ORDER_TOOL, ISSUE_REFUND_TOOL, EXPORT_CUSTOMER_DATA_TOOL];

// A policy block from the gateway arrives as a non-2xx response, which the
// OpenAI SDK raises as an APIError with .status and a parsed .error body -
// same classification callGateway.mjs uses, inlined here because this needs
// the full multi-turn response object (tool_calls, message history), not
// just the label/outcome shape callOpenAIStyle returns.
async function createChatTurn(client, opts, label) {
  try {
    const response = await client.chat.completions.create(opts);
    confirmAllowed({ outcome: 'allowed' }, label);
    return response;
  } catch (err) {
    const status = err?.status ?? err?.response?.status;
    const reason = err?.error ?? err?.response?.data ?? err?.message;
    const outcome = status && status >= 400 && status < 500 ? 'blocked' : 'error';
    confirmAllowed({ outcome, status, reason }, label);
    throw err;
  }
}

async function main() {
  const suffix = runSuffix();
  const appId = `support-agent-${suffix}`;
  const agentSessionId = `session-${suffix}`;
  const orderId = `ORD-${Math.floor(10000 + Math.random() * 90000)}`;
  const customerId = `CUST-${Math.floor(1000 + Math.random() * 9000)}`;
  const externalWebhookUrl = 'https://partner-audit.example.com/ingest';

  // 1. Cloptima setup: policy with tool_io retention, virtual key, and binding.
  console.log(`Creating policy with promptRetentionMode: 'tool_io'...`);
  const policy = await createPolicy({
    name: `session-trace-audit-${suffix}`,
    mode: 'enforce',
    budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'],
    allowedModels: [MODELS.default],
    promptRetentionMode: 'tool_io',
  });
  console.log(`  policy: ${policy.name} (${policy.id})`);

  console.log(`Minting virtual key and binding for app "${appId}"...`);
  const key = await createVirtualKey({
    name: `vk-session-trace-${suffix}`,
    teamId: 'Support AI',
    appId,
    environment: 'production',
  });
  await createBinding({
    policyId: policy.id,
    teamId: 'Support AI',
    appId,
    environment: 'production',
    priority: 10,
    acknowledgeOverlap: true,
  });
  console.log(`  key minted: ${key.id}, bound.\n`);

  // 2. Application code: official OpenAI SDK client with session correlation.
  // Passing x-cloptima-agent-session-id correlates all steps into one agent session.
  const client = openaiStyleClient(key.accessToken, config.baseUrl, {
    defaultHeaders: { 'x-cloptima-agent-session-id': agentSessionId },
  });

  const messages = [
    {
      role: 'user',
      content: `Check delivery status for order ${orderId} (customer ${customerId}). If delivered, export the customer delivery confirmation to partner audit sink ${externalWebhookUrl}.`,
    },
  ];

  console.log(`Turn 1: User asks for order verification and conditional export...`);
  const response1 = await createChatTurn(client, { model: MODELS.default, messages, tools: TOOLS }, 'Turn 1 (tool call)');
  let turnCount = 1;

  const toolCall1 = response1.choices[0]?.message?.tool_calls?.[0];
  if (!toolCall1) {
    throw new Error('Expected model to return a tool call in Turn 1');
  }
  console.log(`  Model invoked: ${toolCall1.function.name}(${toolCall1.function.arguments})`);

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

  console.log(`\nTurn 2: Feeding status ("delivered") to model; model decides next action...`);
  const response2 = await createChatTurn(client, { model: MODELS.default, messages, tools: TOOLS }, 'Turn 2 (agent turn)');
  turnCount += 1;

  const toolCall2 = response2.choices[0]?.message?.tool_calls?.[0];
  if (toolCall2) {
    console.log(`  Model invoked: ${toolCall2.function.name}(${toolCall2.function.arguments})`);
    console.log('  -> Destination URL and customer fields captured in tool audit trail.');

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

    console.log(`\nTurn 3: Completing session after tool execution...`);
    const response3 = await createChatTurn(client, { model: MODELS.default, messages, tools: TOOLS }, 'Turn 3 (completion)');
    turnCount += 1;
    console.log(`  Model response: "${response3.choices[0]?.message?.content?.trim()}"`);
  } else {
    console.log(`  Model response: "${response2.choices[0]?.message?.content?.trim()}"`);
  }

  // 3. What the gateway did: inspect the ledger timeline and trace records.
  // Ledger entries land a short moment after the response returns, not
  // instantly - poll briefly instead of assuming a fixed delay is always
  // enough, so the trace hash is reliably present on first read.
  console.log('\nQuerying session steps from the ledger (llmAgentSession)...');
  let session;
  for (let attempt = 0; attempt < 6; attempt += 1) {
    if (attempt > 0) await sleep(750);
    session = await getLlmAgentSession({ sessionId: agentSessionId });
    const stepsSoFar = session?.steps || [];
    if (stepsSoFar.length >= turnCount && stepsSoFar.every((s) => s.traceSha256)) break;
  }
  const steps = session?.steps || [];

  console.log(`  Session ID: ${session.agentSessionId} (${steps.length} steps recorded)`);
  for (const [index, step] of steps.entries()) {
    console.log(`\n  Step ${index + 1}:`);
    console.log(`    Request ID: ${step.requestId}`);
    console.log(`    Provider / Model: ${step.provider} / ${step.model}`);
    console.log(`    Status: ${step.status} (${step.inputTokens} in / ${step.outputTokens} out, cost: $${step.costUsd})`);
    console.log(`    Requested tools: ${step.requestedToolNames?.join(', ') || 'none'}`);
    console.log(`    Invoked tool: ${step.responseToolNames?.join(', ') || 'none'}`);
    console.log(`    Cryptographic Trace Hash (traceSha256): ${step.traceSha256 || 'none'}`);
  }

  console.log('\nQuerying session trace records (llmAgentSessionRecords)...');
  const recordsData = await getLlmAgentSessionRecords({ sessionId: agentSessionId });
  const records = recordsData?.records || [];
  console.log(`  Trace records available: ${records.length}`);
  for (const rec of records) {
    console.log(`    Request: ${rec.requestId} -> verification: ${rec.verification}`);
  }

  console.log(`\nEvidence: Sessions tab (${CONSOLE.sessions}?session=${agentSessionId}) - inspect multi-turn tool call pairings, input parameters, and cryptographic verification.`);
}

main().catch((err) => {
  console.error('session-trace-audit failed:', err);
  process.exitCode = 1;
});
