// Demonstrates the generic governance queue for a manually-requested change,
// distinct from semantic-cache-enforce.mjs's auto-queued entry. Requests a
// budget increase on an existing policy (approvalType 'budget_limit_change').
// Both requesting and deciding a change need an admin-or-owner identity, so
// an ai:admin key can do either. requestedChange uses the snake_case keys
// daily_budget_usd / monthly_budget_usd, not dailyBudgetUsd. It then lists
// the request pending alongside the approval-type registry itself. The
// actual approve/reject decision is deliberately NOT scripted here for the
// first request - reviewLLMGatewayApproval is a real, callable mutation, but
// this example stops at "request it, show it's pending" and leaves the
// decision to a second identity in the console's Audit tab, same as any real
// governance workflow would require. A second request at the end passes
// applyImmediately: true, which - since this key already qualifies to decide
// this itself - skips that separate step and applies right away.
// Run standalone:
//   node src/examples/approval-workflow.mjs
import { config, runSuffix, CONSOLE } from '../lib/config.mjs';
import { graphql, createPolicy, createVirtualKey, createBinding, createLLMGatewayApproval, listLLMGatewayApprovals } from '../lib/gatewayAdmin.mjs';
import { openaiStyleClient } from '../lib/gatewayClients.mjs';
import { callOpenAIStyle } from '../lib/callGateway.mjs';
import { MODELS } from '../lib/models.mjs';

const CURRENT_DAILY_BUDGET_USD = 5;
const REQUESTED_DAILY_BUDGET_USD = 25;

async function main() {
  const suffix = runSuffix();
  const appId = `approval-workflow-${suffix}`;

  console.log(`Creating a baseline policy with dailyBudgetUsd=$${CURRENT_DAILY_BUDGET_USD}...`);
  const policy = await createPolicy({
    name: `approval-workflow-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    dailyBudgetUsd: CURRENT_DAILY_BUDGET_USD,
  });
  const key = await createVirtualKey({ name: `vk-approval-workflow-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound.\n`);

  console.log('Making one call under the current (unchanged) policy, to show normal traffic is unaffected by a pending request...');
  const client = openaiStyleClient(key.accessToken, config.baseUrl);
  const baseline = await callOpenAIStyle(client, {
    model: MODELS.default,
    prompt: 'In one sentence, confirm this call is running under the current, unmodified policy.',
    label: 'baseline-probe',
  });
  console.log(`  [${baseline.outcome}] baseline-probe`);

  console.log(`\nRequesting approval to raise dailyBudgetUsd from $${CURRENT_DAILY_BUDGET_USD} to $${REQUESTED_DAILY_BUDGET_USD}...`);
  const approval = await createLLMGatewayApproval({
    approvalType: 'budget_limit_change',
    targetId: policy.id,
    requestedChange: { daily_budget_usd: REQUESTED_DAILY_BUDGET_USD },
    affectedApps: [appId],
    affectedRoutes: ['/v1/ai/chat/completions'],
    expectedCostImpactCents: (REQUESTED_DAILY_BUDGET_USD - CURRENT_DAILY_BUDGET_USD) * 100,
    expectedRiskReduction: 'none - this is a budget increase, not a risk-reducing change',
    metadata: { requestedBy: 'approval-workflow example', runSuffix: suffix },
  });
  console.log(`  requested: ${JSON.stringify(approval)}`);

  console.log('\nListing the approval-type registry and this request in the pending queue...');
  const { llmApprovalTypes } = await graphql(
    `query ApprovalTypes { llmApprovalTypes { type targetType requiredRole } }`,
    {},
  );
  console.log(`  registry: ${JSON.stringify(llmApprovalTypes)}`);
  const pending = await listLLMGatewayApprovals({ status: 'pending', limit: 50 });
  const ours = pending.find((a) => a.id === approval.id);
  console.log(`  this request, pending: ${JSON.stringify(ours)}`);

  console.log(
    '\nExpected: the request sits in \'pending\' status and the policy\'s dailyBudgetUsd stays at '
    + `$${CURRENT_DAILY_BUDGET_USD} until a second identity reviews and approves it via reviewLLMGatewayApproval - `
    + `not something this script does on its own behalf.`,
  );

  const requestedDailyBudgetUsd2 = REQUESTED_DAILY_BUDGET_USD + 10;
  console.log('\nRequesting the same kind of budget increase again, this time with applyImmediately: true...');
  const immediateApproval = await createLLMGatewayApproval({
    approvalType: 'budget_limit_change',
    targetId: policy.id,
    requestedChange: { daily_budget_usd: requestedDailyBudgetUsd2 },
    affectedApps: [appId],
    affectedRoutes: ['/v1/ai/chat/completions'],
    expectedCostImpactCents: (requestedDailyBudgetUsd2 - CURRENT_DAILY_BUDGET_USD) * 100,
    expectedRiskReduction: 'none - this is a budget increase, not a risk-reducing change',
    metadata: { requestedBy: 'approval-workflow example', runSuffix: suffix },
    applyImmediately: true,
  });
  console.log(`  result: ${JSON.stringify(immediateApproval)}`);

  console.log(
    '\nExpected: status is \'applied\', not \'pending\' - since this key already qualifies to decide this itself, '
    + 'the request is approved and applied in this same call, with no separate review step.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - shows the first request still pending and this second one already applied; Policies tab (${CONSOLE.policies}) shows the policy's budget reflecting the applied change.`);
}

main().catch((err) => {
  console.error('approval-workflow failed:', err);
  process.exitCode = 1;
});
