/**
 * Automated cleanup script for Cloptima AI gateway example resources.
 *
 * WARNING: This script permanently deletes all AI gateway policies, policy
 * bindings, registered tool servers, and pending approvals, and revokes all
 * active virtual keys in the authenticated account.
 *
 * Intended for sandbox, testing, or demo environments to clean up resources
 * before or after evaluating example scripts.
 *
 * Usage:
 *   npm run cleanup
 *   npm run cleanup -- --force
 *   node src/examples/cleanup.mjs --force
 */

import readline from 'node:readline';
import { config } from '../lib/config.mjs';
import { graphql } from '../lib/gatewayAdmin.mjs';

const isForce = process.argv.includes('--force') ||
  process.argv.includes('-y') ||
  process.env.CI === 'true' ||
  process.env.NONINTERACTIVE === 'true';

const CONTROL_PLANE_QUERY = `
  query GetControlPlaneAndApprovals {
    llmGatewayControlPlane {
      bindings { id policyId teamId appId }
      policies { id name }
      keys { id name status }
      toolServers { id name }
    }
    llmGatewayApprovals(status: "pending", limit: 100) {
      id
      approvalType
      status
    }
  }
`;

const DELETE_BINDING_MUTATION = `
  mutation DeleteBinding($id: ID!) {
    deleteLLMGatewayPolicyBinding(id: $id)
  }
`;

const DELETE_POLICY_MUTATION = `
  mutation DeletePolicy($id: ID!) {
    deleteLLMGatewayPolicy(id: $id)
  }
`;

const DELETE_TOOL_SERVER_MUTATION = `
  mutation DeleteToolServer($id: ID!) {
    deleteLLMGatewayToolServer(id: $id)
  }
`;

const REVOKE_KEY_MUTATION = `
  mutation RevokeKey($id: ID!) {
    revokeLLMGatewayKey(id: $id)
  }
`;

const REJECT_APPROVAL_MUTATION = `
  mutation RejectApproval($id: ID!, $input: LLMGatewayApprovalReviewInput!) {
    reviewLLMGatewayApproval(id: $id, input: $input) {
      id
      status
    }
  }
`;

async function promptConfirmation() {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    rl.question('Are you sure you want to clean up all gateway resources? (y/N): ', (answer) => {
      rl.close();
      const normalized = answer.trim().toLowerCase();
      resolve(normalized === 'y' || normalized === 'yes');
    });
  });
}

async function main() {
  console.log('================================================================================');
  console.log('  WARNING: AI Gateway Account Resource Cleanup');
  console.log('================================================================================');
  console.log('  This script permanently removes ALL AI gateway policies, policy bindings,');
  console.log('  registered tool servers, and pending approvals, and revokes ALL active');
  console.log('  virtual keys in the account associated with the configured CLOPTIMA_AI_ADMIN_KEY.');
  console.log();
  console.log(`  Target Gateway: ${config.baseUrl}`);
  console.log();
  console.log('  Do NOT run this script in an account with production policies or live traffic.');
  console.log('  Use --force or -y to bypass interactive confirmation in automated workflows.');
  console.log('================================================================================\n');

  if (process.stdin.isTTY && !isForce) {
    const confirmed = await promptConfirmation();
    if (!confirmed) {
      console.log('Cleanup aborted.');
      process.exit(0);
    }
    console.log();
  }

  console.log('Fetching existing gateway resources...');
  const data = await graphql(CONTROL_PLANE_QUERY);
  const { bindings = [], policies = [], keys = [], toolServers = [] } = data.llmGatewayControlPlane || {};
  const approvals = data.llmGatewayApprovals || [];

  const activeKeys = keys.filter((k) => k.status !== 'revoked');

  console.log(`Found:`);
  console.log(`  - ${bindings.length} policy binding(s)`);
  console.log(`  - ${policies.length} policy/policies`);
  console.log(`  - ${toolServers.length} registered tool server(s)`);
  console.log(`  - ${activeKeys.length} active virtual key(s) (${keys.length} total)`);
  console.log(`  - ${approvals.length} pending approval request(s)`);
  console.log();

  if (
    bindings.length === 0 &&
    policies.length === 0 &&
    toolServers.length === 0 &&
    activeKeys.length === 0 &&
    approvals.length === 0
  ) {
    console.log('Account is already clean. No resources to delete.');
    return;
  }

  // 1. Delete bindings first so policies have no active bindings
  let deletedBindings = 0;
  for (const binding of bindings) {
    try {
      await graphql(DELETE_BINDING_MUTATION, { id: binding.id });
      deletedBindings++;
    } catch (err) {
      console.warn(`  Failed to delete binding ${binding.id}: ${err.message}`);
    }
  }
  console.log(`✓ Deleted ${deletedBindings}/${bindings.length} policy binding(s)`);

  // 2. Delete policies
  let deletedPolicies = 0;
  for (const policy of policies) {
    try {
      await graphql(DELETE_POLICY_MUTATION, { id: policy.id });
      deletedPolicies++;
    } catch (err) {
      console.warn(`  Failed to delete policy ${policy.name} (${policy.id}): ${err.message}`);
    }
  }
  console.log(`✓ Deleted ${deletedPolicies}/${policies.length} policy/policies`);

  // 3. Delete tool servers
  let deletedToolServers = 0;
  for (const server of toolServers) {
    try {
      await graphql(DELETE_TOOL_SERVER_MUTATION, { id: server.id });
      deletedToolServers++;
    } catch (err) {
      console.warn(`  Failed to delete tool server ${server.name} (${server.id}): ${err.message}`);
    }
  }
  console.log(`✓ Deleted ${deletedToolServers}/${toolServers.length} tool server(s)`);

  // 4. Revoke active virtual keys
  let revokedKeys = 0;
  for (const key of activeKeys) {
    try {
      await graphql(REVOKE_KEY_MUTATION, { id: key.id });
      revokedKeys++;
    } catch (err) {
      console.warn(`  Failed to revoke virtual key ${key.name || key.id}: ${err.message}`);
    }
  }
  console.log(`✓ Revoked ${revokedKeys}/${activeKeys.length} active virtual key(s)`);

  // 5. Reject pending approvals
  let rejectedApprovals = 0;
  for (const approval of approvals) {
    try {
      await graphql(REJECT_APPROVAL_MUTATION, {
        id: approval.id,
        input: { decision: 'reject', reason: 'Automated cleanup' },
      });
      rejectedApprovals++;
    } catch (err) {
      console.warn(`  Failed to reject approval ${approval.id}: ${err.message}`);
    }
  }
  console.log(`✓ Rejected ${rejectedApprovals}/${approvals.length} pending approval request(s)`);

  console.log('\nCleanup completed successfully.');
}

main().catch((err) => {
  console.error('\nCleanup failed:', err.message);
  process.exit(1);
});
