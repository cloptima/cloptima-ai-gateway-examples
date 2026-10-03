/**
 * Automated cleanup script for Cloptima AI gateway example resources.
 *
 * WARNING: This script permanently deletes every AI gateway policy, policy
 * binding, guardrail profile, registered tool server, eval dataset, and ROI
 * calibration in the authenticated account. It also archives prompt templates
 * and price sheets, revokes all active virtual keys and provider credentials,
 * and rejects all pending approvals.
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

const INVENTORY_QUERY = `
  query GetCleanupInventory {
    llmGatewayControlPlane {
      bindings { id policyId teamId appId }
      policies { id name }
      keys { id name status }
      credentials { id displayName status }
      toolServers { id name }
    }
    llmGuardrailProfiles { id name }
    llmGatewayApprovals(status: "pending", limit: 100) { id approvalType status }
    llmPromptTemplates(limit: 100) { id name }
    llmDatasets(limit: 100) { id name }
    llmContractPriceSheets { id name status }
    llmROICalibrations { id }
  }
`;

// Each step removes one resource type. Order matters: bindings go before the
// policies they reference, and policies go before the guardrail profiles they
// reference.
const STEPS = [
  {
    label: 'policy binding(s)',
    items: (d) => d.llmGatewayControlPlane.bindings,
    run: (item) => graphql('mutation($id: ID!) { deleteLLMGatewayPolicyBinding(id: $id) }', { id: item.id }),
  },
  {
    label: 'policy/policies',
    items: (d) => d.llmGatewayControlPlane.policies,
    run: (item) => graphql('mutation($id: ID!) { deleteLLMGatewayPolicy(id: $id) }', { id: item.id }),
  },
  {
    label: 'guardrail profile(s)',
    items: (d) => d.llmGuardrailProfiles,
    run: (item) => graphql('mutation($id: ID!) { deleteLLMGuardrailProfile(id: $id) }', { id: item.id }),
  },
  {
    label: 'tool server(s)',
    items: (d) => d.llmGatewayControlPlane.toolServers,
    run: (item) => graphql('mutation($id: ID!) { deleteLLMGatewayToolServer(id: $id) }', { id: item.id }),
  },
  {
    label: 'active virtual key(s)',
    verb: 'Revoked',
    items: (d) => d.llmGatewayControlPlane.keys.filter((k) => k.status !== 'revoked'),
    run: (item) => graphql('mutation($id: ID!) { revokeLLMGatewayKey(id: $id) }', { id: item.id }),
  },
  {
    label: 'active provider credential(s)',
    verb: 'Revoked',
    items: (d) => d.llmGatewayControlPlane.credentials.filter((c) => c.status !== 'revoked'),
    run: (item) => graphql('mutation($id: ID!) { revokeLLMProviderCredential(id: $id) }', { id: item.id }),
  },
  {
    label: 'pending approval request(s)',
    verb: 'Rejected',
    items: (d) => d.llmGatewayApprovals,
    run: (item) => graphql(
      `mutation($id: ID!, $input: LLMGatewayApprovalReviewInput!) {
        reviewLLMGatewayApproval(id: $id, input: $input) { id }
      }`,
      { id: item.id, input: { decision: 'reject', reason: 'Automated cleanup' } },
    ),
  },
  {
    label: 'prompt template(s)',
    verb: 'Archived',
    items: (d) => d.llmPromptTemplates,
    run: (item) => graphql('mutation($id: ID!) { archiveLLMPromptTemplate(id: $id) }', { id: item.id }),
  },
  {
    label: 'eval dataset(s)',
    items: (d) => d.llmDatasets,
    run: (item) => graphql('mutation($id: ID!) { deleteLLMDataset(id: $id) }', { id: item.id }),
  },
  {
    label: 'active price sheet(s)',
    verb: 'Archived',
    items: (d) => d.llmContractPriceSheets.filter((p) => p.status !== 'archived'),
    run: (item) => graphql('mutation($id: ID!) { archivePriceSheet(id: $id) { id } }', { id: item.id }),
  },
  {
    label: 'ROI calibration(s)',
    items: (d) => d.llmROICalibrations,
    run: (item) => graphql('mutation($id: ID!) { deleteROICalibration(id: $id) }', { id: item.id }),
  },
];

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
  console.log('  guardrail profiles, tool servers, eval datasets, and ROI calibrations;');
  console.log('  archives ALL prompt templates and price sheets; revokes ALL virtual keys');
  console.log('  and provider credentials; and rejects ALL pending approvals in the account');
  console.log('  associated with the configured CLOPTIMA_AI_ADMIN_KEY.');
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

  let cleanedAny = false;
  let previousFingerprint;
  for (;;) {
    console.log(cleanedAny ? 'Checking for remaining gateway resources...' : 'Fetching existing gateway resources...');
    const inventory = await graphql(INVENTORY_QUERY);
    const plan = STEPS.map((step) => ({ ...step, found: step.items(inventory) }));
    const remaining = plan.reduce((total, step) => total + step.found.length, 0);

    if (remaining === 0) {
      console.log(cleanedAny ? '\nCleanup completed successfully.' : 'Account is already clean. No resources to delete.');
      return;
    }

    const fingerprint = plan
      .flatMap(({ label, found }) => found.map((item) => `${label}:${item.id}`))
      .sort()
      .join('|');
    if (fingerprint === previousFingerprint) {
      throw new Error('cleanup made no progress; one or more resources remain');
    }
    previousFingerprint = fingerprint;

    console.log('Found:');
    for (const { label, found } of plan) console.log(`  - ${found.length} ${label}`);
    console.log();

    let failures = 0;
    for (const { label, verb = 'Deleted', found, run } of plan) {
      let done = 0;
      for (const item of found) {
        try {
          await run(item);
          done++;
        } catch (err) {
          failures++;
          console.warn(`  Failed on ${label} ${item.name || item.displayName || item.id}: ${err.message}`);
        }
      }
      console.log(`✓ ${verb} ${done}/${found.length} ${label}`);
    }

    if (failures > 0) {
      throw new Error(`${failures} resource(s) could not be removed`);
    }
    cleanedAny = true;
  }
}

main().catch((err) => {
  console.error('\nCleanup failed:', err.message);
  process.exit(1);
});
