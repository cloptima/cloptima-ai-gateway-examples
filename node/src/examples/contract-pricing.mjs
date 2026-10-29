/**
 * Enterprise Contract Pricing & Rate Overrides
 *
 * When an enterprise negotiates custom volume pricing with a model provider
 * (e.g., volume discount on input and output tokens), those contracted rates
 * govern the customer's direct provider accounts (BYOK).
 *
 * Cloptima's FinOps engine reconciles these custom rate sheets against standard
 * retail catalog rates, accurately tracking:
 * 1. Retail list price spend
 * 2. Contracted effective spend
 * 3. Realized enterprise cost savings
 *
 * Requires PROVIDER_API_KEY or CLOPTIMA_PROVIDER_CREDENTIAL_ID in .env.
 */
import { openaiClient } from '../lib/client.mjs';
import { provisionApp } from '../lib/access.mjs';
import { runSuffix } from '../lib/config.mjs';
import { adminApi } from '../lib/gatewayAdmin.mjs';

const PROVIDER = 'openai';
const MODEL = 'gpt-4o-mini';
const CANONICAL_MODEL = 'openai/gpt-4o-mini';
const CONTRACT_INPUT_RATE = 0.12;  // Retail is $0.15 / 1M tokens (~20% discount)
const CONTRACT_OUTPUT_RATE = 0.48; // Retail is $0.60 / 1M tokens (~20% discount)

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function resolveProviderCredentialId() {
  if (process.env.CLOPTIMA_PROVIDER_CREDENTIAL_ID) {
    return process.env.CLOPTIMA_PROVIDER_CREDENTIAL_ID;
  }

  const providerApiKey = process.env.PROVIDER_API_KEY;
  if (!providerApiKey) {
    throw new Error(
      'Missing required env var PROVIDER_API_KEY or CLOPTIMA_PROVIDER_CREDENTIAL_ID.\n' +
      'Set PROVIDER_API_KEY in .env with your OpenAI API key to test contracted pricing.'
    );
  }

  const suffix = runSuffix();
  console.log('Registering provider credential (BYOK)...');
  const created = await adminApi('POST', '/v1/llm/provider-credentials', {
    body: { provider: PROVIDER, display_name: `byok-openai-${suffix}`, api_key: providerApiKey },
  });
  return created.id;
}

async function setupEnterprisePriceSheet(suffix) {
  const now = new Date();
  const effectiveEnd = new Date(now);
  effectiveEnd.setUTCFullYear(effectiveEnd.getUTCFullYear() + 1);

  console.log(`Setting up enterprise price sheet with negotiated rates for ${MODEL}...`);
  const priceSheet = await adminApi('POST', '/v1/llm/pricing/sheets', {
    body: {
      name: `Enterprise Agreement (${suffix})`,
      owner: 'cloptima-ai-gateway-examples',
      effective_start: now.toISOString(),
      effective_end: effectiveEnd.toISOString(),
    },
  });
  const sheetPath = `/v1/llm/pricing/sheets/${encodeURIComponent(priceSheet.id)}`;

  await adminApi('POST', `${sheetPath}/overrides`, {
    body: {
      overrides: [{
        provider: PROVIDER,
        model: MODEL,
        input_rate_per_million: CONTRACT_INPUT_RATE,
        output_rate_per_million: CONTRACT_OUTPUT_RATE,
        effective_start: now.toISOString(),
        effective_end: effectiveEnd.toISOString(),
      }],
    },
  });

  await adminApi('POST', `${sheetPath}/approve`);

  console.log(`Enterprise price sheet approved: ${priceSheet.id}`);
  return priceSheet;
}

async function main() {
  const suffix = runSuffix();
  const credentialId = await resolveProviderCredentialId();
  await setupEnterprisePriceSheet(suffix);

  console.log('\nInitializing OpenAI client pointing to Cloptima Gateway...');
  // Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy,
  // key, and binding once in the Console, Terraform, or CI.
  const { virtualKey } = await provisionApp({
    app: 'contract-pricing-demo',
    policy: {
      name: 'contract-pricing-policy',
      mode: 'enforce',
      budget_mode: 'hard',
      allowed_providers: [PROVIDER],
      allowed_models: [CANONICAL_MODEL],
    },
  });

  // Application code: the credential header routes the call through your own provider account,
  // which is where the negotiated rates apply.
  const client = openaiClient(virtualKey, {
    defaultHeaders: { 'x-cloptima-provider-credential-id': credentialId },
  });

  const prompts = [
    'Explain how committed-use discounts optimize cloud spend in one concise sentence.',
    'Explain the distinction between retail list price and effective contracted rate in one sentence.',
  ];

  const verificationStart = new Date().toISOString();
  console.log('\nExecuting enterprise queries billed under negotiated rates:');
  for (const [i, prompt] of prompts.entries()) {
    try {
      const response = await client.chat.completions.create({
        model: CANONICAL_MODEL,
        messages: [{ role: 'user', content: prompt }],
        temperature: 0.5,
      });
      console.log(`\nQuery ${i + 1}: "${prompt}"`);
      console.log(`Answer: ${response.choices[0]?.message?.content?.trim()}`);
      console.log(`Tokens: in=${response.usage?.prompt_tokens}, out=${response.usage?.completion_tokens}`);
    } catch (err) {
      console.error(`Query ${i + 1} failed:`, err?.message || err);
    }
  }

  console.log('\nReconciling FinOps metrics against Cloptima Finance Dashboard...');
  let dashboard = null;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    if (attempt > 0) await sleep(2000);
    try {
      const d = await adminApi('GET', '/v1/llm/finance/dashboard', {
        query: { window: 'custom', start_time: verificationStart, end_time: new Date().toISOString() },
      });
      if (d?.has_active_contract) {
        dashboard = d;
        break;
      }
    } catch {
      // Continue retrying
    }
  }

  if (dashboard) {
    console.log('\n--- FinOps Reconciliation Summary ---');
    console.log(`Active Enterprise Contract: ${dashboard.has_active_contract ? 'Yes' : 'No'}`);
    console.log(`Standard Retail Cost: $${dashboard.retail_cost_usd}`);
    console.log(`Effective Contracted Cost: $${dashboard.contracted_cost_usd}`);
    const savings = Number(dashboard.retail_cost_usd) - Number(dashboard.contracted_cost_usd);
    console.log(`Realized Savings: $${savings.toFixed(4)}`);
  } else {
    console.log('Finance dashboard metrics recorded; newly approved rate sheets reconcile in reporting shortly.');
  }
}

main().catch((err) => {
  console.error('contract-pricing execution failed:', err.message);
  process.exitCode = 1;
});
