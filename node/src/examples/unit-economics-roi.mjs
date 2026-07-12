// Seeds two unit-economics scenarios side by side - a cost center and a
// profit center - so both ways of measuring an LLM agent's business value
// show up as real numbers, not claims:
//
// 1. A support-automation agent (cost center): resolving a ticket avoids a
//    pre-LLM support cost rather than booking revenue, so its value is
//    tracked as calibratedBusinessValueUsd/netRoiUsd against an ROI
//    calibration row (value per success, and what handling it manually used
//    to cost).
// 2. A checkout-upsell agent (profit center): each accepted upsell books
//    real revenue_usd, so its value shows up as a positive marginUsd
//    (revenue - spend) instead.
//
// Run standalone:
//   node src/examples/unit-economics-roi.mjs
import { config, runSuffix, USER_AGENT, CONSOLE } from '../lib/config.mjs';
import { graphql, createPolicy, createVirtualKey, createBinding } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { attributionHeaders } from '../lib/attribution.mjs';
import { MODELS } from '../lib/models.mjs';

const COST_CENTER_TRANSACTION_TYPE = 'support_ticket_resolved';
const PROFIT_CENTER_TRANSACTION_TYPE = 'checkout_upsell_accepted';

async function submitUnitMetrics({ unitType, unitCount, successCount, windowStart, windowEnd, teamId, appId, transactionType, revenueUsd }) {
  const metric = {
    unit_type: unitType,
    unit_count: unitCount,
    successful_unit_count: successCount,
    window_start: windowStart,
    window_end: windowEnd,
    team_id: teamId, app_id: appId, environment: 'prod',
    business_transaction_type: transactionType,
  };
  if (revenueUsd !== undefined) metric.revenue_usd = revenueUsd.toFixed(2);
  const response = await fetch(`${config.baseUrl}/v1/ai/integrations/unit-metrics`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'user-agent': USER_AGENT, authorization: `Bearer ${config.aiAdminKey}` },
    body: JSON.stringify({ metrics: [metric] }),
  });
  const body = await response.json().catch(() => null);
  console.log(`Unit-metrics status=${response.status} body=${JSON.stringify(body)}`);
}

async function readUnitEconomics(unitType) {
  try {
    const report = await graphql(
      `query UnitEconomics($unitType: String!, $groupBy: String!, $window: String) {
        llmUnitEconomics(unitType: $unitType, groupBy: $groupBy, window: $window) {
          rows { bucket unitCount costPerUnitUsd marginUsd netRoiUsd calibratedBusinessValueUsd missingMetadata }
        }
      }`,
      { unitType, groupBy: 'app_id', window: '30d' },
    );
    console.log(JSON.stringify(report.llmUnitEconomics.rows, null, 2));
  } catch (err) {
    console.log(`Report not available yet (ledger aggregation may lag ingest): ${err.message}`);
  }
}

async function main() {
  const suffix = runSuffix();

  // --- Cost center: support automation -------------------------------
  const supportAppId = `unit-economics-support-${suffix}`;
  console.log(`Seeding an ROI calibration row for "${COST_CENTER_TRANSACTION_TYPE}" (illustrative, not customer-validated)...`);
  const now = new Date();
  const effectiveEnd = new Date(now);
  effectiveEnd.setUTCFullYear(effectiveEnd.getUTCFullYear() + 1);
  await graphql(
    `mutation UpsertROI($input: UpsertROICalibrationInput!) { upsertROICalibration(input: $input) { id } }`,
    {
      input: {
        transactionType: COST_CENTER_TRANSACTION_TYPE,
        valuePerSuccessCents: 800,
        preLlmBaselineCostCents: 350,
        owner: 'cloptima-ai-gateway-examples',
        effectiveStart: now.toISOString(),
        effectiveEnd: effectiveEnd.toISOString(),
      },
    },
  );
  console.log('ROI calibration seeded.');

  console.log('Creating a policy + key and making a few real support-automation calls...');
  const supportPolicy = await createPolicy({
    name: `unit-economics-support-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
  });
  const supportKey = await createVirtualKey({ name: `vk-unit-economics-support-${suffix}`, teamId: 'Support Automation', appId: supportAppId, environment: 'prod' });
  await createBinding({ policyId: supportPolicy.id, teamId: 'Support Automation', appId: supportAppId, environment: 'prod', priority: 10, acknowledgeOverlap: true });

  const supportClient = openaiStyleClient(supportKey.accessToken, config.baseUrl);
  // The unit-metrics window is anchored to the calibration's own effective
  // start, since the report only counts calibrated business value for the
  // portion of the window the calibration was active for.
  const supportWindowStart = now.toISOString();
  const supportPrompts = [
    'A customer says their invoice total looks wrong for this month. Draft a short reply asking for the invoice number.',
    'A customer cannot log in after resetting their password. Draft a short reply with the next step.',
    'A customer wants to know why their monthly bill increased. Draft a short reply.',
  ];
  let supportSuccessCount = 0;
  for (const [i, prompt] of supportPrompts.entries()) {
    const result = await callOpenAIStyle(supportClient, {
      model: MODELS.default, prompt,
      headers: attributionHeaders({
        teamId: 'Support Automation', appId: supportAppId, environment: 'prod',
        businessTransactionType: COST_CENTER_TRANSACTION_TYPE,
        businessTransactionId: `${suffix}-support-${i}`,
        businessTransactionUnitCount: 1,
        businessOutcomeStatus: 'resolved',
        businessValueCents: 750,
      }),
      label: `support-ticket-${i + 1}`,
    });
    if (result.outcome === 'allowed') supportSuccessCount += 1;
    console.log(`  [${result.outcome}] support-ticket-${i + 1}`);
  }

  console.log('\nSubmitting a unit-metrics batch for the support-automation window...');
  await submitUnitMetrics({
    unitType: 'support_answers',
    unitCount: supportPrompts.length,
    successCount: supportSuccessCount,
    windowStart: supportWindowStart,
    windowEnd: new Date().toISOString(),
    teamId: 'Support Automation',
    appId: supportAppId,
    transactionType: COST_CENTER_TRANSACTION_TYPE,
  });

  // --- Profit center: checkout upsell agent ---------------------------
  const upsellAppId = `unit-economics-upsell-${suffix}`;
  console.log('\nCreating a policy + key and making a few real checkout-upsell calls...');
  const upsellPolicy = await createPolicy({
    name: `unit-economics-upsell-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
  });
  const upsellKey = await createVirtualKey({ name: `vk-unit-economics-upsell-${suffix}`, teamId: 'Checkout Upsell', appId: upsellAppId, environment: 'prod' });
  await createBinding({ policyId: upsellPolicy.id, teamId: 'Checkout Upsell', appId: upsellAppId, environment: 'prod', priority: 10, acknowledgeOverlap: true });

  const upsellClient = openaiStyleClient(upsellKey.accessToken, config.baseUrl);
  const upsellWindowStart = new Date().toISOString();
  const upsells = [
    { prompt: 'A customer just added running shoes to their cart. Write a one-sentence checkout upsell for moisture-wicking socks.', acceptedValueUsd: 12.99 },
    { prompt: 'A customer just added a laptop to their cart. Write a one-sentence checkout upsell for a protective sleeve.', acceptedValueUsd: 24.99 },
    { prompt: 'A customer just added a coffee maker to their cart. Write a one-sentence checkout upsell for a bag of specialty coffee beans.', acceptedValueUsd: 16.99 },
  ];
  let upsellSuccessCount = 0;
  let acceptedRevenueUsd = 0;
  for (const [i, { prompt, acceptedValueUsd }] of upsells.entries()) {
    const result = await callOpenAIStyle(upsellClient, {
      model: MODELS.default, prompt,
      headers: attributionHeaders({
        teamId: 'Checkout Upsell', appId: upsellAppId, environment: 'prod',
        businessTransactionType: PROFIT_CENTER_TRANSACTION_TYPE,
        businessTransactionId: `${suffix}-upsell-${i}`,
        businessTransactionUnitCount: 1,
        businessOutcomeStatus: 'accepted',
        businessValueCents: Math.round(acceptedValueUsd * 100),
      }),
      label: `checkout-upsell-${i + 1}`,
    });
    if (result.outcome === 'allowed') {
      upsellSuccessCount += 1;
      acceptedRevenueUsd += acceptedValueUsd;
    }
    console.log(`  [${result.outcome}] checkout-upsell-${i + 1} ($${acceptedValueUsd.toFixed(2)} if accepted)`);
  }

  console.log('\nSubmitting a unit-metrics batch for the checkout-upsell window, with the real revenue those accepted upsells booked...');
  await submitUnitMetrics({
    unitType: 'checkout_upsells',
    unitCount: upsells.length,
    successCount: upsellSuccessCount,
    windowStart: upsellWindowStart,
    windowEnd: new Date().toISOString(),
    teamId: 'Checkout Upsell',
    appId: upsellAppId,
    transactionType: PROFIT_CENTER_TRANSACTION_TYPE,
    revenueUsd: acceptedRevenueUsd,
  });

  console.log('\nReading back the cost-center report (support automation - value shows up as calibrated ROI, not margin)...');
  await readUnitEconomics('support_answers');

  console.log('\nReading back the profit-center report (checkout upsell - value shows up as a positive margin from real revenue)...');
  await readUnitEconomics('checkout_upsells');

  console.log(`\nEvidence: Economics tab (${CONSOLE.unitEconomics}) shows both apps side by side - cost-per-unit, margin, and net-ROI, grouped by app.`);
}

main().catch((err) => {
  console.error('unit-economics-roi failed:', err);
  process.exitCode = 1;
});
