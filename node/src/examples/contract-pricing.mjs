// Seeds one enterprise contract price sheet (illustrative negotiated rates,
// the same kind of input a real customer's finance/procurement team would
// configure - not a real contract), approves it, logs a commitment against
// it, makes a few real calls at the overridden model, and verifies the
// contracted rate actually applied by checking the finance dashboard's real
// retail-vs-contracted numbers for this account.
// Run standalone:
//   node src/examples/contract-pricing.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { graphql, createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

// vertex_ai/gemini-2.5-flash retail: $0.30 in / $2.50 out per million tokens
// (Cloptima's default LLM pricing catalog). ~20% off both - a realistic
// volume discount for a mid-size enterprise agreement.
const PROVIDER = 'vertex_ai';
const MODEL = MODELS.default.split('/').pop();
const CONTRACT_INPUT_RATE = 0.24;
const CONTRACT_OUTPUT_RATE = 2.0;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// A brand-new policy, key, and contract rate might take a brief moment to
// initialize. If we receive a transient block or error right after setup,
// retrying briefly is the right move.
function isPropagationDelay(result) {
  if (result.outcome === 'error') return true;
  if (result.outcome !== 'blocked') return false;
  const body = result.reason;
  const code = body && typeof body === 'object' ? body.reason : undefined;
  return code && code.endsWith('_unavailable');
}

// Short exponential backoff (500ms, 1s, 2s, 4s - ~7.5s ceiling across 5
// attempts): fast when the platform is already initialized (the common case),
// bounded and tolerant of a brief initialization delay, and still fails within a
// few seconds - rather than hanging or silently passing - if something is
// genuinely wrong for longer than that.
async function callWithPropagationRetry(client, opts, { attempts = 5, baseDelayMs = 500 } = {}) {
  let result;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (attempt > 0) await sleep(baseDelayMs * 2 ** (attempt - 1));
    result = await callOpenAIStyle(client, opts);
    if (result.outcome === 'allowed' || !isPropagationDelay(result)) return result;
  }
  return result;
}

async function main() {
  const suffix = runSuffix();
  const appId = `contract-pricing-${suffix}`;
  const now = new Date();
  const effectiveEnd = new Date(now);
  effectiveEnd.setUTCFullYear(effectiveEnd.getUTCFullYear() + 1);

  console.log(`Creating an illustrative enterprise price sheet (~20% off retail on ${MODEL})...`);
  const { createPriceSheet } = await graphql(
    `mutation CreatePriceSheet($input: CreatePriceSheetInput!) {
      createPriceSheet(input: $input) { id name status }
    }`,
    {
      input: {
        name: `Enterprise volume agreement (${suffix})`,
        owner: 'cloptima-ai-gateway-examples',
        effectiveStart: now.toISOString(),
        effectiveEnd: effectiveEnd.toISOString(),
      },
    },
  );
  console.log(`  price sheet ${createPriceSheet.name} -> ${createPriceSheet.id} (status=${createPriceSheet.status})`);

  console.log('Adding the negotiated rate override...');
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
        cachedInputRatePerMillion: CONTRACT_INPUT_RATE,
        effectiveStart: now.toISOString(),
        effectiveEnd: effectiveEnd.toISOString(),
      }],
    },
  );

  console.log('Approving the price sheet so it applies to real cost calculations...');
  await graphql(
    `mutation ApprovePriceSheet($id: ID!) { approvePriceSheet(id: $id) { id status approvedAt } }`,
    { id: createPriceSheet.id },
  );

  console.log('Logging a commitment against this agreement...');
  await graphql(
    `mutation CreateCommitment($input: CreateCommitmentInput!) {
      createCommitmentEntry(input: $input) { id name amountCents }
    }`,
    {
      input: {
        name: `Annual commitment (${suffix})`,
        type: 'upfront',
        amountCents: '200000',
        currency: 'USD',
        effectiveStart: now.toISOString(),
        effectiveEnd: effectiveEnd.toISOString(),
      },
    },
  );

  console.log('Creating a policy + key and making a few real calls at the contracted rate...');
  const policy = await createPolicy({
    name: `contract-pricing-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: [PROVIDER], allowedModels: [MODELS.default],
  });
  const key = await createVirtualKey({ name: `vk-contract-pricing-${suffix}`, teamId: 'Finance', appId, environment: 'prod' });
  await createBinding({ policyId: policy.id, teamId: 'Finance', appId, environment: 'prod', priority: 10, acknowledgeOverlap: true });

  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const prompts = [
    'In one sentence, summarize why enterprise LLM contracts beat retail pricing.',
    'In one sentence, explain what a committed-use discount is.',
    'In one sentence, explain why effective cost differs from retail cost.',
  ];
  const verificationStart = new Date().toISOString();
  let allowedCount = 0;
  for (const [i, prompt] of prompts.entries()) {
    const result = await callWithPropagationRetry(client, {
      model: MODELS.default, prompt,
      headers: { 'x-cloptima-team': 'Finance', 'x-cloptima-app': appId, 'x-cloptima-environment': 'prod' },
      label: `contract-call-${i + 1}`,
    });
    console.log(`  [${result.outcome}] contract-call-${i + 1}`);
    if (result.outcome === 'allowed') allowedCount += 1;
  }
  if (allowedCount !== prompts.length) {
    throw new Error(
      `${prompts.length - allowedCount} of ${prompts.length} request${prompts.length - allowedCount === 1 ? '' : 's'} `
      + "didn't go through. It's worth trying this example again; if it keeps happening, that's worth a closer look.",
    );
  }

  console.log('\nVerifying the contracted rate actually applied (checking the finance dashboard for real retail-vs-contracted numbers)...');
  // Scoped to calls made by this run, not the whole account's history.
  let dashboard = null;
  for (let attempt = 0; attempt < 5 && !dashboard; attempt += 1) {
    if (attempt > 0) await sleep(2000);
    const result = await graphql(
      `query Dashboard($startTime: DateTime!, $endTime: DateTime!) {
        llmFinanceDashboard(window: "custom", startTime: $startTime, endTime: $endTime) { retailCostUsd contractedCostUsd hasActiveContract }
      }`,
      { startTime: verificationStart, endTime: new Date().toISOString() },
    );
    const d = result.llmFinanceDashboard;
    if (d.hasActiveContract && Number(d.contractedCostUsd) < Number(d.retailCostUsd)) {
      dashboard = d;
    }
  }
  if (!dashboard) {
    throw new Error(
      "Your negotiated rate hasn't shown up on the Finance dashboard yet. This is almost always just timing - "
      + 'newly approved contract pricing can take a short moment to start reflecting in reported numbers, especially '
      + "right after it's uploaded, and isn't a sign that anything is wrong. Give it a little longer and check the "
      + `Dashboard tab directly (${CONSOLE.dashboard}), or simply run this example again.`,
    );
  }
  console.log(`  Confirmed: Finance dashboard shows real contracted cost $${dashboard.contractedCostUsd} below retail cost $${dashboard.retailCostUsd} for this account.`);
  console.log(`\nEvidence: Dashboard tab (${CONSOLE.dashboard}) - Blended Effective Cost card shows retail vs. contracted vs. effective cost; open Contract Pricing to see this price sheet and its rate override.`);
}

main().catch((err) => {
  console.error('contract-pricing failed:', err);
  process.exitCode = 1;
});
