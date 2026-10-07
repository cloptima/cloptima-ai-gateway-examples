/**
 * Quickstart: Connecting the Anthropic SDK to Cloptima AI Gateway
 *
 * Demonstrates standard Anthropic SDK integration:
 * 1. Initialize the official Anthropic SDK with Cloptima's base URL and virtual key.
 * 2. Send standard and streaming Messages requests through the gateway.
 * 3. Inspect usage and request metadata.
 *
 * Run standalone:
 *   node src/examples/quickstart-anthropic.mjs
 */
import Anthropic from '@anthropic-ai/sdk';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE, config } from '../lib/config.mjs';

async function main() {
  console.log('=== Cloptima AI Gateway: Anthropic SDK Quickstart ===\n');

  // Governance setup: the policy this application runs under. Platform admins normally
  //    create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
  //    points at a key whose policy already matches.
  const access = await getAccess({
    app: 'quickstart-demo',
    policy: {
      name: 'quickstart-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = new Anthropic({
    apiKey: access.virtualKey,
    baseURL: config.baseUrl, // the SDK appends /v1/messages
  });

  // 1. Standard Messages API Call
  console.log('--- 1. Standard Messages API Request ---');
  const response = await client.messages.create({
    model: MODELS.default,
    max_tokens: 300,
    messages: [
      { role: 'user', content: 'What are the main benefits of centralized LLM gateway governance?' },
    ],
  });

  const text = response.content?.[0]?.text || '';
  console.log(`Assistant:\n  ${text.trim()}\n`);
  console.log(`Tokens: ${response.usage?.input_tokens} input, ${response.usage?.output_tokens} output`);
  console.log(`Request ID: ${response.id}\n`);

  // 2. Streaming Messages Call
  console.log('--- 2. Streaming Messages Request ---');
  const stream = await client.messages.create({
    model: MODELS.default,
    max_tokens: 100,
    messages: [{ role: 'user', content: 'List 3 cloud cost best practices briefly.' }],
    stream: true,
  });

  process.stdout.write('Assistant: ');
  for await (const event of stream) {
    if (event.type === 'content_block_delta' && event.delta?.text) {
      process.stdout.write(event.delta.text);
    }
  }
  console.log('\n');

  console.log(`View live spend, latency, and attribution in the console: ${CONSOLE.spend}`);
}

main().catch((err) => {
  console.error('Quickstart failed:', err.message);
  process.exitCode = 1;
});
