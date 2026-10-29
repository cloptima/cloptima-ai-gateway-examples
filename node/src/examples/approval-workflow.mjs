/**
 * Enterprise Governance: Policy Change Requests & Approval Queues
 *
 * In regulated enterprise environments, developers and automated services cannot
 * unilaterally increase production spend limits or modify security controls.
 *
 * Cloptima provides a two-phase governance queue:
 * 1. An application operates normally within its allocated daily budget ($5.00/day).
 * 2. An engineering team or automation submits a change request to raise the budget
 *    to $25.00/day via Cloptima's Governance API.
 * 3. The request enters the governance queue with status 'pending'. Active application
 *    traffic continues to run without disruption under the existing policy.
 * 4. Enterprise administrators review and approve pending requests in the Cloptima
 *    Console or through authorized CI/CD automation (apply_immediately: true), activating
 *    the new budget limit live.
 */
import { openaiClient } from '../lib/client.mjs';
import { provisionApp } from '../lib/access.mjs';
import { createApproval, listApprovals } from '../lib/gatewayAdmin.mjs';
import { MODELS } from '../lib/models.mjs';

const CURRENT_DAILY_BUDGET_USD = 5;
const REQUESTED_DAILY_BUDGET_USD = 25;

async function main() {
  console.log(`Initializing application with baseline daily budget of $${CURRENT_DAILY_BUDGET_USD}...`);
  // Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy,
  // key, and binding once in the Console, Terraform, or CI.
  const { virtualKey, policy, appId } = await provisionApp({
    app: 'governed-app-demo',
    policy: {
      name: 'governance-approval-policy',
      mode: 'enforce',
      budget_mode: 'hard',
      allowed_providers: ['vertex_ai'],
      allowed_models: [MODELS.default],
      daily_budget_usd: CURRENT_DAILY_BUDGET_USD,
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(virtualKey);

  console.log('\nExecuting normal application query under existing policy...');
  try {
    const baseline = await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: 'Confirm this application is running normally.' }],
      temperature: 0.3,
    });
    console.log('Application status: Active (200 OK)');
    console.log(`Response: "${baseline.choices[0]?.message?.content?.trim()}"`);
  } catch (err) {
    console.error('Baseline query failed:', err?.message || err);
  }

  console.log(`\nSubmitting governance change request to raise daily budget to $${REQUESTED_DAILY_BUDGET_USD}...`);
  const approval = await createApproval({
    approval_type: 'budget_limit_change',
    target_id: policy.id,
    requested_change: { daily_budget_usd: REQUESTED_DAILY_BUDGET_USD },
    affected_apps: [appId],
    affected_routes: ['/v1/ai/chat/completions'],
    expected_cost_impact_cents: (REQUESTED_DAILY_BUDGET_USD - CURRENT_DAILY_BUDGET_USD) * 100,
    expected_risk_reduction: 'none - planned capacity increase for Q4 peak load',
  });
  console.log(`Change request submitted: ID ${approval.id} (Status: ${approval.status})`);

  console.log('\nInspecting enterprise governance queue...');
  const pending = await listApprovals({ status: 'pending', limit: 50 });
  const pendingMatch = pending.items.find((a) => a.id === approval.id);
  if (pendingMatch) {
    console.log(`Approval queue entry: ID ${pendingMatch.id} is pending secondary review.`);
    console.log('Production safety: Existing $5.00 limit remains active until administrator approval.');
  }

  console.log('\nExecuting post-request traffic to demonstrate uninterrupted runtime:');
  try {
    const postRequest = await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: 'What is the primary benefit of change approval queues in enterprise software?' }],
      temperature: 0.3,
    });
    console.log(`Response: "${postRequest.choices[0]?.message?.content?.trim()}"`);
  } catch (err) {
    console.error('Post-request query failed:', err?.message || err);
  }

  console.log('\nDemonstrating automated CI/CD approval with pre-authorized identity (apply_immediately: true)...');
  const automatedApproval = await createApproval({
    approval_type: 'budget_limit_change',
    target_id: policy.id,
    requested_change: { daily_budget_usd: REQUESTED_DAILY_BUDGET_USD + 10 },
    affected_apps: [appId],
    affected_routes: ['/v1/ai/chat/completions'],
    expected_cost_impact_cents: (REQUESTED_DAILY_BUDGET_USD + 10 - CURRENT_DAILY_BUDGET_USD) * 100,
    expected_risk_reduction: 'pre-authorized CI/CD deployment',
    apply_immediately: true,
  });
  console.log(`Automated approval result: ID ${automatedApproval.id} (Status: ${automatedApproval.status})`);
  console.log('Governance state: Applied immediately, policy daily budget updated live.');
}

main().catch((err) => {
  console.error('approval-workflow execution failed:', err.message);
  process.exitCode = 1;
});
