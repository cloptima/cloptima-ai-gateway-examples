/**
 * Knowledge Base & Customer Support: Real-Time Semantic Cache Enforcement
 *
 * In high-scale customer support and search applications, users frequently ask
 * questions with identical meaning using slightly different phrasing:
 * - "How do I upgrade my team subscription?"
 * - "Where can I change our plan to enterprise?"
 * - "What is the procedure to upgrade my organization's plan?"
 *
 * Cloptima's gateway provides multi-tiered caching:
 * 1. Exact Cache: Verbatim string matches served instantly with zero provider cost.
 * 2. Semantic Cache: High-dimensional vector matching that intercepts paraphrased
 *    queries and serves cached answers without dispatching to the LLM provider.
 *
 * This example executes:
 * - Cold query: Model generates response; answer is cached.
 * - Exact repeat queries: Served via Exact Cache (ultra-low latency, 0 tokens).
 * - Semantically paraphrased queries: Served via Semantic Cache (zero token spend).
 */
import { openaiClient } from '../lib/client.mjs';
import { provisionApp } from '../lib/access.mjs';
import { graphql } from '../lib/gatewayAdmin.mjs';
import { MODELS } from '../lib/models.mjs';

const ROUTE = '/v1/ai/chat/completions';
const MODEL_FAMILY = MODELS.default;

async function ensureClassApproval(appId) {
  const { createLLMSemanticCacheClassApproval: approval } = await graphql(
    `mutation CreateClassApproval($input: LLMSemanticCacheClassApprovalInput!) {
      createLLMSemanticCacheClassApproval(input: $input) { id appId route modelFamily createdAt }
    }`,
    { input: { appId, route: ROUTE, modelFamily: MODEL_FAMILY, notes: 'semantic-cache-enforce example' } },
  );
  return approval;
}

async function queryWithLatency(client, prompt, label) {
  const start = Date.now();
  try {
    const response = await client.chat.completions.create({
      model: MODELS.default,
      messages: [
        { role: 'system', content: 'You are an IT support assistant. Answer concisely in one sentence.' },
        { role: 'user', content: prompt },
      ],
      temperature: 0.1,
    });
    const durationMs = Date.now() - start;
    const answer = response.choices[0]?.message?.content?.trim();
    return { outcome: 'success', durationMs, answer, prompt, label };
  } catch (err) {
    const durationMs = Date.now() - start;
    return { outcome: 'error', durationMs, error: err?.message || err, prompt, label };
  }
}

async function main() {
  console.log('Connecting to Cloptima Gateway with Enforce-Mode Semantic Caching...');
  // Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy,
  // key, and binding once in the Console, Terraform, or CI.
  const { virtualKey, appId } = await provisionApp({
    app: 'semantic-cache-demo',
    policy: {
      name: 'semantic-cache-enforce-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
      promptRetentionMode: 'full',
      exactCacheEnabled: true,
      exactCacheMode: 'enforce',
      semanticCacheEnabled: true,
      semanticCacheMode: 'enforce',
      applyImmediately: true,
    },
  });
  // Semantic-cache enforce mode needs a class approval for this app, route, and model family.
  await ensureClassApproval(appId);

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(virtualKey);

  // 1. Cold Request
  const primaryPrompt = 'How do I generate a new Personal Access Token for the Cloptima API?';
  console.log(`\n[Cold Query] Sending initial question: "${primaryPrompt}"`);
  const cold = await queryWithLatency(client, primaryPrompt, 'Cold Query');
  console.log(`Result: ${cold.durationMs}ms latency | Answer: "${cold.answer}"`);

  // 2. Exact Cache Repeat
  console.log('\n[Exact Cache] Sending identical repeat query:');
  const exact = await queryWithLatency(client, primaryPrompt, 'Exact Cache Hit');
  console.log(`Result: ${exact.durationMs}ms latency (${Math.round((cold.durationMs - exact.durationMs) / cold.durationMs * 100)}% faster)`);
  console.log(`Answer: "${exact.answer}"`);

  // 3. Semantically Paraphrased Queries
  const paraphrasedPrompts = [
    'Where can I create a Personal Access Token to access the Cloptima API?',
    'What are the steps to get an API personal access token in Cloptima?',
  ];

  console.log('\n[Semantic Cache] Sending semantically equivalent questions with different phrasing:');
  for (const [i, prompt] of paraphrasedPrompts.entries()) {
    const sem = await queryWithLatency(client, prompt, `Semantic Variant ${i + 1}`);
    console.log(`\nVariant ${i + 1}: "${prompt}"`);
    console.log(`Result: ${sem.durationMs}ms latency | Answer: "${sem.answer}"`);
  }

  console.log('\n--- Cache Performance Summary ---');
  console.log(`Cold LLM Provider Latency: ${cold.durationMs}ms`);
  console.log(`Exact Cache Latency:        ${exact.durationMs}ms`);
  console.log('Governance & Economic Impact:');
  console.log('- High cache hit rate reduces backend provider API costs to $0 for recurring questions');
  console.log('- Sub-second response times improve end-user satisfaction for customer-facing chatbots');
}

main().catch((err) => {
  console.error('semantic-cache-enforce execution failed:', err.message);
  process.exitCode = 1;
});
