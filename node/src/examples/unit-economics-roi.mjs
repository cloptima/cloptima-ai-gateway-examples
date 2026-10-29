/**
 * Measuring LLM Business Value & Unit Economics: Cost Center vs Profit Center
 *
 * This example demonstrates how production applications attribute real business value
 * and financial return to LLM inference calls using Cloptima:
 *
 * 1. Customer Support Automation (Cost Center):
 *    Resolving a customer inquiry avoids manual tier-1 support costs ($3.50 baseline).
 *    Its value is tracked through calibrated Net ROI (avoided cost minus LLM spend).
 *
 * 2. E-Commerce Checkout Upsell (Profit Center):
 *    Recommending complementary products at checkout generates incremental revenue.
 *    Its value is tracked through Gross Margin (booked revenue minus LLM spend).
 *
 * Applications pass business outcome headers directly on inference calls:
 * - x-cloptima-business-transaction-type
 * - x-cloptima-business-outcome-status
 * - x-cloptima-business-value-cents
 */
import { openaiClient } from '../lib/client.mjs';
import { provisionApp } from '../lib/access.mjs';
import { config, runSuffix, USER_AGENT } from '../lib/config.mjs';
import { adminApi } from '../lib/gatewayAdmin.mjs';
import { attributionHeaders } from '../lib/attribution.mjs';
import { MODELS } from '../lib/models.mjs';

const COST_CENTER_TYPE = 'support_ticket_resolved';
const PROFIT_CENTER_TYPE = 'checkout_upsell_accepted';

// The report fields this example prints. Each row carries more.
const REPORT_FIELDS = [
  'bucket', 'unit_count', 'cost_per_unit_usd', 'margin_usd', 'net_roi_usd', 'calibrated_business_value_usd', 'missing_metadata',
];

async function seedRoiCalibration(suffix) {
  const now = new Date();
  const effectiveEnd = new Date(now);
  effectiveEnd.setUTCFullYear(effectiveEnd.getUTCFullYear() + 1);

  console.log(`Configuring FinOps ROI calibration for "${COST_CENTER_TYPE}"...`);
  // Each call records the transaction type's next calibration version.
  await adminApi('POST', '/v1/llm/roi/calibrations', {
    body: {
      transaction_type: COST_CENTER_TYPE,
      value_per_success_cents: 800,        // $8.00 estimated business value
      pre_llm_baseline_cost_cents: 350,    // $3.50 manual support handling cost
      owner: 'cloptima-ai-gateway-examples',
      effective_start: now.toISOString(),
      effective_end: effectiveEnd.toISOString(),
    },
  });
}

async function submitUnitMetrics({ unitType, unitCount, successCount, windowStart, windowEnd, teamId, appId, transactionType, revenueUsd }) {
  const metric = {
    unit_type: unitType,
    unit_count: unitCount,
    successful_unit_count: successCount,
    window_start: windowStart,
    window_end: windowEnd,
    team_id: teamId,
    app_id: appId,
    environment: 'production',
    business_transaction_type: transactionType,
  };
  if (revenueUsd !== undefined) metric.revenue_usd = revenueUsd.toFixed(2);

  const response = await fetch(`${config.baseUrl}/v1/ai/integrations/unit-metrics`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'user-agent': USER_AGENT,
      authorization: `Bearer ${config.aiAdminKey}`,
    },
    body: JSON.stringify({ metrics: [metric] }),
  });
  return response.status;
}

async function fetchUnitEconomicsReport(unitType) {
  try {
    const report = await adminApi('GET', '/v1/llm/unit-economics', {
      query: { unit_type: unitType, group_by: 'app_id', window: '30d' },
    });
    const rows = report?.results?.find((result) => result.unit_type === unitType)?.rows || [];
    return rows.map((row) => Object.fromEntries(REPORT_FIELDS.map((field) => [field, row[field]])));
  } catch (err) {
    console.log(`  (Report aggregation pending: ${err.message})`);
    return [];
  }
}

async function main() {
  const suffix = runSuffix();
  await seedRoiCalibration(suffix);

  // Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy,
  // key, and binding once in the Console, Terraform, or CI.
  const { virtualKey, appId } = await provisionApp({
    app: 'unit-economics-demo',
    policy: {
      name: 'unit-economics-policy',
      mode: 'enforce',
      budget_mode: 'hard',
      allowed_providers: ['vertex_ai'],
      allowed_models: [MODELS.default],
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(virtualKey);

  // --- Scenario 1: Support Automation (Cost Center) ---
  console.log('\n--- Scenario 1: Support Automation (Cost Center) ---');
  const supportTickets = [
    { id: `${suffix}-sup-1`, query: 'How do I update the billing email address for my organization?' },
    { id: `${suffix}-sup-2`, query: 'My API requests are failing with HTTP 401 unauthorized. Where do I get a new token?' },
  ];

  const supportStart = new Date().toISOString();
  let supportSuccesses = 0;

  for (const [i, ticket] of supportTickets.entries()) {
    try {
      const response = await client.chat.completions.create(
        {
          model: MODELS.default,
          messages: [
            { role: 'system', content: 'You are an automated support resolution assistant. Answer concisely in one sentence.' },
            { role: 'user', content: ticket.query },
          ],
        },
        {
          headers: attributionHeaders({
            businessTransactionType: COST_CENTER_TYPE,
            businessTransactionId: ticket.id,
            businessTransactionUnitCount: 1,
            businessOutcomeStatus: 'resolved',
            businessOutcomeSuccess: true,
            businessValueCents: 750,
          }),
        },
      );

      supportSuccesses += 1;
      console.log(`[Ticket ${i + 1}] Resolved: ${ticket.query}`);
      console.log(`Answer: ${response.choices[0]?.message?.content?.trim()}`);
    } catch (err) {
      console.error(`Ticket ${i + 1} failed:`, err?.message || err);
    }
  }

  await submitUnitMetrics({
    unitType: 'support_answers',
    unitCount: supportTickets.length,
    successCount: supportSuccesses,
    windowStart: supportStart,
    windowEnd: new Date().toISOString(),
    teamId: 'Support Automation',
    appId,
    transactionType: COST_CENTER_TYPE,
  });
  console.log(`Submitted support unit metrics batch (${supportSuccesses}/${supportTickets.length} resolved).`);

  // --- Scenario 2: E-Commerce Upsell (Profit Center) ---
  console.log('\n--- Scenario 2: E-Commerce Upsell (Profit Center) ---');
  const upsells = [
    { item: 'Wireless Headphones', upsell: 'Protective Carrying Case', valueUsd: 19.99 },
    { item: 'Espresso Machine', upsell: 'Organic Coffee Beans (1kg)', valueUsd: 24.50 },
  ];

  const upsellStart = new Date().toISOString();
  let totalRevenueUsd = 0;
  let upsellSuccesses = 0;

  for (const [i, item] of upsells.entries()) {
    try {
      const response = await client.chat.completions.create(
        {
          model: MODELS.default,
          messages: [
            { role: 'system', content: 'Generate a short 1-sentence checkout upsell recommendation.' },
            { role: 'user', content: `Customer bought: ${item.item}. Suggest: ${item.upsell}.` },
          ],
        },
        {
          headers: attributionHeaders({
            businessTransactionType: PROFIT_CENTER_TYPE,
            businessTransactionId: `${suffix}-upsell-${i + 1}`,
            businessTransactionUnitCount: 1,
            businessOutcomeStatus: 'accepted',
            businessOutcomeSuccess: true,
            businessValueCents: Math.round(item.valueUsd * 100),
          }),
        },
      );

      upsellSuccesses += 1;
      totalRevenueUsd += item.valueUsd;
      console.log(`[Upsell ${i + 1}] Item: ${item.item} -> Suggested: ${item.upsell} (Value: $${item.valueUsd})`);
      console.log(`Pitch: ${response.choices[0]?.message?.content?.trim()}`);
    } catch (err) {
      console.error(`Upsell ${i + 1} failed:`, err?.message || err);
    }
  }

  await submitUnitMetrics({
    unitType: 'checkout_upsells',
    unitCount: upsells.length,
    successCount: upsellSuccesses,
    windowStart: upsellStart,
    windowEnd: new Date().toISOString(),
    teamId: 'Growth Engineering',
    appId,
    transactionType: PROFIT_CENTER_TYPE,
    revenueUsd: totalRevenueUsd,
  });
  console.log(`Submitted upsell unit metrics batch ($${totalRevenueUsd.toFixed(2)} booked revenue).`);

  // --- Unit Economics & ROI Reporting ---
  console.log('\n--- Cloptima Unit Economics & ROI Reports ---');
  const supportReport = await fetchUnitEconomicsReport('support_answers');
  if (supportReport.length > 0) {
    console.log('Support Automation (Cost Avoidance / Net ROI):', JSON.stringify(supportReport, null, 2));
  } else {
    console.log('Support Automation metrics recorded. View aggregated ROI cards in Cloptima Economics tab.');
  }

  const upsellReport = await fetchUnitEconomicsReport('checkout_upsells');
  if (upsellReport.length > 0) {
    console.log('Checkout Upsell (Direct Revenue / Gross Margin):', JSON.stringify(upsellReport, null, 2));
  } else {
    console.log('Checkout Upsell metrics recorded. View gross margin cards in Cloptima Economics tab.');
  }
}

main().catch((err) => {
  console.error('unit-economics-roi execution failed:', err.message);
  process.exitCode = 1;
});
