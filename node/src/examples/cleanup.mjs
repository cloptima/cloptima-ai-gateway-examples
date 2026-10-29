/**
 * Automated cleanup script for Cloptima AI gateway example resources.
 *
 * WARNING: This script permanently deletes every AI gateway policy, policy
 * binding, guardrail profile, registered tool server, and ROI calibration in
 * the authenticated account. It also archives price sheets, revokes all active
 * virtual keys and provider credentials, and rejects all pending approvals.
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
import { adminApi } from '../lib/gatewayAdmin.mjs';

const isForce = process.argv.includes('--force') ||
  process.argv.includes('-y') ||
  process.env.CI === 'true' ||
  process.env.NONINTERACTIVE === 'true';

const PAGE_SIZE = 100;

// Reads every page of a cursor-paged list.
async function listAll(path, query = {}) {
  const items = [];
  let cursor;
  do {
    const page = await adminApi('GET', path, { query: { ...query, limit: PAGE_SIZE, cursor } });
    items.push(...page.items);
    cursor = page.next_cursor;
  } while (cursor);
  return items;
}

// Virtual keys page by offset.
async function listActiveKeys() {
  const items = [];
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const page = await adminApi('GET', '/v1/llm/gateway-keys', { query: { status: 'active', limit: PAGE_SIZE, offset } });
    items.push(...page.items);
    if (!page.has_more) return items;
  }
}

const remove = (path) => (item) => adminApi('DELETE', `${path}/${encodeURIComponent(item.id)}`);

// Each step removes one resource type. Order matters: bindings go before the
// policies they reference, and policies go before the guardrail profiles they
// reference.
const STEPS = [
  {
    label: 'policy binding(s)',
    list: () => listAll('/v1/llm/policy-bindings'),
    run: remove('/v1/llm/policy-bindings'),
  },
  {
    label: 'policy/policies',
    list: () => listAll('/v1/llm/policies'),
    run: remove('/v1/llm/policies'),
  },
  {
    label: 'guardrail profile(s)',
    list: () => listAll('/v1/llm/guardrail-profiles'),
    run: remove('/v1/llm/guardrail-profiles'),
  },
  {
    label: 'tool server(s)',
    list: () => listAll('/v1/llm/tool-servers'),
    run: remove('/v1/llm/tool-servers'),
  },
  {
    label: 'active virtual key(s)',
    verb: 'Revoked',
    list: listActiveKeys,
    run: remove('/v1/llm/gateway-keys'),
  },
  {
    label: 'active provider credential(s)',
    verb: 'Revoked',
    list: () => listAll('/v1/llm/provider-credentials', { status: 'active' }),
    run: remove('/v1/llm/provider-credentials'),
  },
  {
    label: 'pending approval request(s)',
    verb: 'Rejected',
    planGated: true, // llm_approval_workflows
    list: () => listAll('/v1/llm/approvals', { status: 'pending' }),
    run: (item) => adminApi('POST', `/v1/llm/approvals/${encodeURIComponent(item.id)}/review`, {
      body: { decision: 'reject', reason: 'Automated cleanup' },
    }),
  },
  {
    label: 'active price sheet(s)',
    verb: 'Archived',
    planGated: true, // llm_contract_pricing
    list: async () => (await listAll('/v1/llm/pricing/sheets')).filter((sheet) => sheet.status !== 'archived'),
    run: (item) => adminApi('POST', `/v1/llm/pricing/sheets/${encodeURIComponent(item.id)}/archive`),
  },
  {
    label: 'ROI calibration(s)',
    // This list is not paged.
    list: async () => (await adminApi('GET', '/v1/llm/roi/calibrations')).items,
    run: remove('/v1/llm/roi/calibrations'),
  },
];

// A plan-gated step whose list call answers HTTP 403 is not on this plan: it is
// skipped for the rest of the run. Any other list error fails the run.
async function listStep(step) {
  try {
    return await step.list();
  } catch (err) {
    if (!step.planGated || err.status !== 403) throw err;
    console.log(`Skipped ${step.label}: not available on this plan.`);
    return null;
  }
}

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
  console.log('  guardrail profiles, tool servers, and ROI calibrations; archives ALL price');
  console.log('  sheets; revokes ALL virtual keys and provider credentials; and rejects ALL');
  console.log('  pending approvals in the account associated with the configured');
  console.log('  CLOPTIMA_AI_ADMIN_KEY.');
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
  let steps = STEPS;
  for (;;) {
    console.log(cleanedAny ? 'Checking for remaining gateway resources...' : 'Fetching existing gateway resources...');
    const plan = [];
    for (const step of steps) {
      const found = await listStep(step);
      if (found) plan.push({ ...step, found });
    }
    steps = plan;
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
          console.warn(`  Failed on ${label} ${item.name || item.display_name || item.id}: ${err.message}`);
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
