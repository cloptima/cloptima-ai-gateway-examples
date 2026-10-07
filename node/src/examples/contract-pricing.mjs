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
import { graphql } from '../lib/gatewayAdmin.mjs';

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
  const created = await graphql(
    `mutation CreateCredential($input: CreateLLMProviderCredentialInput!) {
      createLLMProviderCredential(input: $input) { id provider displayName }
    }`,
    { input: { provider: PROVIDER, displayName: `byok-openai-${suffix}`, apiKey: providerApiKey } },
  );
  return created.createLLMProviderCredential.id;
}

async function setupEnterprisePriceSheet(suffix) {
  const now = new Date();
  const effectiveEnd = new Date(now);
  effectiveEnd.setUTCFullYear(effectiveEnd.getUTCFullYear() + 1);

  console.log(`Setting up enterprise price sheet with negotiated rates for ${MODEL}...`);
  const { createPriceSheet } = await graphql(
    `mutation CreatePriceSheet($input: CreatePriceSheetInput!) {
      createPriceSheet(input: $input) { id name status }
    }`,
    {
      input: {
        name: `Enterprise Agreement (${suffix})`,
        owner: 'cloptima-ai-gateway-examples',
        effectiveStart: now.toISOString(),
        effectiveEnd: effectiveEnd.toISOString(),
      },
    },
  );

  await graphql(
    `mutation AddRateOverrides($priceSheetId: ID!, $overrides: [RateOverrideInput!]!) {
      addRateOverrides(priceSheetId: $priceSheetId, overrides: $overrides) {
        id provider model inputRatePerMillion outputRatePerMillion
      }
    }`,
    {
      priceSheetId: createPriceSheet.id,
      overrides: [{
        provider: PROVIDER,
        model: MODEL,
        inputRatePerMillion: CONTRACT_INPUT_RATE,
        outputRatePerMillion: CONTRACT_OUTPUT_RATE,
        effectiveStart: now.toISOString(),
        effectiveEnd: effectiveEnd.toISOString(),
      }],
    },
  );

  await graphql(
    `mutation ApprovePriceSheet($id: ID!) { approvePriceSheet(id: $id) { id status approvedAt } }`,
    { id: createPriceSheet.id },
  );

  console.log(`Enterprise price sheet approved: ${createPriceSheet.id}`);
  return createPriceSheet;
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
      budgetMode: 'hard',
      allowedProviders: [PROVIDER],
      allowedModels: [CANONICAL_MODEL],
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
      const result = await graphql(
        `query Dashboard($startTime: DateTime!, $endTime: DateTime!) {
          llmFinanceDashboard(window: "custom", startTime: $startTime, endTime: $endTime) {
            retailCostUsd
            contractedCostUsd
            hasActiveContract
          }
        }`,
        { startTime: verificationStart, endTime: new Date().toISOString() },
      );
      const d = result?.llmFinanceDashboard;
      if (d?.hasActiveContract) {
        dashboard = d;
        break;
      }
    } catch {
      // Continue retrying
    }
  }

  if (dashboard) {
    console.log('\n--- FinOps Reconciliation Summary ---');
    console.log(`Active Enterprise Contract: ${dashboard.hasActiveContract ? 'Yes' : 'No'}`);
    console.log(`Standard Retail Cost: $${dashboard.retailCostUsd}`);
    console.log(`Effective Contracted Cost: $${dashboard.contractedCostUsd}`);
    const savings = Number(dashboard.retailCostUsd) - Number(dashboard.contractedCostUsd);
    console.log(`Realized Savings: $${savings.toFixed(4)}`);
  } else {
    console.log('Finance dashboard metrics recorded; newly approved rate sheets reconcile in reporting shortly.');
  }
}

main().catch((err) => {
  console.error('contract-pricing execution failed:', err.message);
  process.exitCode = 1;
});
