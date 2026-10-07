/**
 * Quickstart: Connecting the OpenAI SDK to Cloptima AI Gateway
 *
 * Demonstrates standard client integration:
 * 1. Initialize the official OpenAI SDK with Cloptima's base URL and virtual key.
 * 2. Send standard and streaming chat completion requests.
 * 3. Inspect request attribution and token usage.
 *
 * Run standalone:
 *   node src/examples/quickstart-openai.mjs
 */
import OpenAI from 'openai';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE, config } from '../lib/config.mjs';

async function main() {
  console.log('=== Cloptima AI Gateway: OpenAI SDK Quickstart ===\n');

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
  // Tip: In production services where you want to inspect policy/guardrail block details
  // (such as err.error.violations and err.error.reason), use the client helper from
  // src/lib/client.mjs which preserves these gateway fields on raised SDK errors.
  const client = new OpenAI({
    apiKey: access.virtualKey,
    baseURL: `${config.baseUrl}/v1/ai`, // the SDK appends /chat/completions
  });

  // 1. Standard Chat Completion
  console.log('--- 1. Standard Chat Completion ---');
  const completion = await client.chat.completions.create({
    model: MODELS.default,
    messages: [
      { role: 'system', content: 'You are a helpful cloud engineer.' },
      { role: 'user', content: 'Explain what an AI gateway does in one clear sentence.' },
    ],
  });

  console.log(`Assistant: ${completion.choices[0].message.content.trim()}`);
  console.log(`Tokens: ${completion.usage?.total_tokens} (prompt: ${completion.usage?.prompt_tokens}, completion: ${completion.usage?.completion_tokens})`);
  console.log(`Request ID: ${completion.id}\n`);

  // 2. Streaming Chat Completion
  console.log('--- 2. Streaming Chat Completion ---');
  const stream = await client.chat.completions.create({
    model: MODELS.default,
    messages: [{ role: 'user', content: 'Count from 1 to 5 with commas.' }],
    stream: true,
  });

  process.stdout.write('Assistant: ');
  for await (const chunk of stream) {
    process.stdout.write(chunk.choices[0]?.delta?.content || '');
  }
  console.log('\n');

  console.log(`View live spend, latency, and attribution in the console: ${CONSOLE.spend}`);
}

main().catch((err) => {
  console.error('Quickstart failed:', err.message);
  process.exitCode = 1;
});
