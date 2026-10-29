/**
 * Knowledge Base & FAQ Retrieval with Exact and Semantic Caching
 *
 * Demonstrates how Cloptima's caching layer reduces latency and eliminates model
 * token costs on repeated or semantically similar queries.
 *
 * Pattern:
 * 1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
 * 2. Query 1: Initial user query (Cache Miss) -> routed to model, normal latency.
 * 3. Query 2: Identical query (Exact Cache Hit) -> served instantly from gateway cache at 0 token cost.
 * 4. Query 3: Paraphrased queries -> evaluated by the gateway's semantic cache engine.
 *
 * Run standalone:
 *   node src/examples/exact-semantic-cache.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// A new policy takes effect a few seconds after it is created. A response is
// stored in the exact cache a few seconds after it is served, so an identical
// request sent sooner is a cache miss.
const POLICY_PROPAGATION_MS = 10000;
const CACHE_FILL_MS = 6000;

async function timedCompletion(client, prompt, label) {
  const start = Date.now();
  const response = await client.chat.completions.create({
    model: MODELS.default,
    messages: [{ role: 'user', content: prompt }],
  });
  const elapsedMs = Date.now() - start;
  return {
    label,
    elapsedMs,
    content: response.choices[0]?.message?.content?.trim() || '',
    usage: response.usage,
    id: response.id,
  };
}

async function main() {
  console.log('=== FAQ & Knowledge Search: Exact & Semantic Caching ===\n');

  // Governance setup: the policy this application runs under. Platform admins normally
  //    create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
  //    points at a key whose policy already matches.
  const access = await getAccess({
    app: 'knowledge-cache-demo',
    policy: {
      name: 'knowledge-cache-policy',
      mode: 'enforce',
      budget_mode: 'hard',
      allowed_providers: ['vertex_ai'],
      allowed_models: [MODELS.default],
      exact_cache_enabled: true,
      exact_cache_mode: 'enforce',
      exact_cache_ttl_seconds: 3600,
      semantic_cache_enabled: true,
      semantic_cache_mode: 'observe',
      semantic_cache_similarity_threshold: 0.85,
    },
  });

  if (access.provisioned) {
    console.log(`Waiting ${POLICY_PROPAGATION_MS / 1000}s for the new policy to take effect...\n`);
    await sleep(POLICY_PROPAGATION_MS);
  }

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  // 2. Query 1: Initial query (Cache Miss)
  const query = 'How do I configure automatic database backups in Kubernetes?';
  console.log(`--- Query 1: Initial Request (Cold Miss) ---`);
  console.log(`User: "${query}"`);

  const initial = await timedCompletion(client, query, 'Initial Call');
  console.log(`Assistant: ${initial.content}`);
  console.log(`Latency: ${initial.elapsedMs}ms | Tokens: ${initial.usage?.total_tokens}\n`);

  // Give the exact cache time to store the first response before repeating the query.
  await sleep(CACHE_FILL_MS);

  // 3. Query 2: Repeated identical query (Exact Cache Hit)
  console.log(`--- Query 2: Repeated Identical Request (Exact Cache Hit) ---`);
  console.log(`User: "${query}"`);

  const cached = await timedCompletion(client, query, 'Cached Call');
  console.log(`Assistant: ${cached.content}`);
  console.log(`Latency: ${cached.elapsedMs}ms (vs ${initial.elapsedMs}ms initial) | Tokens: ${cached.usage?.total_tokens}\n`);

  if (cached.elapsedMs < initial.elapsedMs) {
    console.log(`⚡ Performance improvement: ~${Math.round(((initial.elapsedMs - cached.elapsedMs) / initial.elapsedMs) * 100)}% latency reduction via gateway cache.\n`);
  }

  // 4. Query 3: Semantically similar paraphrased variants
  console.log(`--- Query 3: Semantically Similar Paraphrased Queries ---`);
  const paraphrasedVariants = [
    'What is the procedure for setting up automated K8s DB backups?',
    'How can I automate database backups inside a Kubernetes cluster?',
  ];

  for (const [index, variant] of paraphrasedVariants.entries()) {
    console.log(`Variant ${index + 1}: "${variant}"`);
    const res = await timedCompletion(client, variant, `Variant ${index + 1}`);
    console.log(`  Latency: ${res.elapsedMs}ms\n`);
  }

  console.log(`Evidence in Cloptima Console:`);
  console.log(`  - Cache performance & savings: ${CONSOLE.spend}`);
  console.log(`  - Policies & cache configuration: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
