// MCP tool governance: registration, approval, allowed tools, and definition review.
//
// The first registration waits for review. A qualifying admin then creates a
// second, immediately active server so this example can show definition drift.
// The final checks use provider-called MCP tools, whose access is checked before inference.
//
// Run standalone:
//   node src/examples/mcp-tool-governance.mjs

import { config, runSuffix, CONSOLE, USER_AGENT } from '../lib/config.mjs';
import { graphql, createPolicy, createVirtualKey, createBinding, listLLMGatewayApprovals } from '../lib/gatewayAdmin.mjs';
import { confirmBlocked, confirmEquals } from '../lib/confirm.mjs';
import { MODELS } from '../lib/models.mjs';

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function callResponsesApi(accessToken, requireApproval, serverLabel, allowedTools = ['search']) {
  const response = await fetch(`${config.baseUrl}/v1/ai/responses`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'user-agent': USER_AGENT,
      authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      model: MODELS.default,
      input: `Test call with require_approval: ${requireApproval}.`,
      tools: [{ type: 'mcp', server_label: serverLabel, allowed_tools: allowedTools, require_approval: requireApproval }],
    }),
  });
  const body = await response.json();
  const outcome = response.status === 200 ? 'allowed' : (response.status >= 400 && response.status < 500 ? 'blocked' : 'error');
  return { outcome, status: response.status, body };
}

async function callChatCompletions(accessToken, toolDef, prompt) {
  const response = await fetch(`${config.baseUrl}/v1/ai/chat/completions`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'user-agent': USER_AGENT,
      authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      model: MODELS.default,
      messages: [{ role: 'user', content: prompt }],
      tools: [toolDef],
    }),
  });
  const body = await response.json();
  const outcome = response.status === 200 ? 'allowed' : (response.status >= 400 && response.status < 500 ? 'blocked' : 'error');
  return { outcome, status: response.status, body };
}

async function queryToolDefinitions(serverId) {
  const data = await graphql(
    `query GetToolDefs($serverId: ID) {
      llmGatewayToolDefinitions(serverId: $serverId) {
        definitions {
          toolName
          definitionSha256
          status
        }
      }
    }`,
    { serverId },
  );
  return data.llmGatewayToolDefinitions;
}

async function waitForToolDefinitions(serverId, predicate, timeoutMs = 15000, intervalMs = 1000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const res = await queryToolDefinitions(serverId);
    if (predicate(res)) {
      return res;
    }
    await sleep(intervalMs);
  }
  return await queryToolDefinitions(serverId);
}

async function reviewToolDefinition(serverId, toolName, definitionSha256, decision) {
  const data = await graphql(
    `mutation ReviewToolDef($input: LLMGatewayToolDefinitionReviewInput!) {
      reviewLLMGatewayToolDefinition(input: $input) {
        status
      }
    }`,
    {
      input: {
        serverId,
        toolName,
        definitionSha256,
        decision,
      },
    },
  );
  return data.reviewLLMGatewayToolDefinition;
}

async function main() {
  const suffix = runSuffix();
  const appId = `mcp-tool-governance-${suffix}`;
  const serverLabel = `example-mcp-server-${suffix}`;

  // ---------------------------------------------------------------------------
  // 1. Registration and approval
  // ---------------------------------------------------------------------------
  console.log(`Registering a tool server (label ${serverLabel}, requesting status: active)...`);
  const { createLLMGatewayToolServer: toolServer } = await graphql(
    `mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
      createLLMGatewayToolServer(input: $input) { id name serverType status allowedToolNames }
    }`,
    {
      input: {
        name: serverLabel,
        serverType: 'mcp',
        serverUrl: 'https://example.com/mcp',
        status: 'active',
        allowedToolNames: ['search', 'lookup'],
      },
    },
  );
  console.log(`  tool server ${toolServer.id} (${toolServer.name}) - actual status: ${toolServer.status} (forced to 'disabled' pending review, regardless of the 'active' requested above)`);

  console.log("\nChecking the generic governance queue for the auto-queued mcp_tool_server_registration approval...");
  const pending = await listLLMGatewayApprovals({ status: 'pending', limit: 50 });
  const autoQueued = pending.find((a) => a.approvalType === 'mcp_tool_server_registration' && a.targetId === toolServer.id);
  if (autoQueued) {
    console.log(`  pending: ${JSON.stringify(autoQueued)}`);
    console.log(
      '  This script leaves the approval pending. An eligible owner or admin can review it in the '
      + `console's Audit tab (${CONSOLE.audit}). Until reviewed, this tool server stays 'disabled' and any call `
      + 'through it is blocked.',
    );
  } else {
    console.log('  no matching pending entry found (it may already have been reviewed on a prior run of this example).');
  }

  console.log('\nCreating a policy that allows only this tool server...');
  const policy = await createPolicy({
    name: `mcp-tool-governance-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    allowedToolServers: [serverLabel],
  });
  const key = await createVirtualKey({ name: `vk-mcp-tool-governance-${suffix}`, teamId: 'Platform AI', appId, environment: 'dev' });
  await createBinding({ policyId: policy.id, teamId: 'Platform AI', appId, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted key ${key.id}, bound.\n`);

  console.log('Dry-run simulating whether this tool server/tool would be allowed under the policy...');
  const { llmGatewayToolPolicySimulation: simulation } = await graphql(
    `query Simulate($input: LLMGatewayToolPolicySimulationInput!) {
      llmGatewayToolPolicySimulation(input: $input) {
        allowed reason violations
        policy { id name }
        toolServer { id name }
      }
    }`,
    {
      input: {
        toolServerName: serverLabel,
        toolName: 'search',
        teamId: 'Platform AI',
        appId,
        environment: 'dev',
      },
    },
  );
  console.log(`  simulation: ${JSON.stringify(simulation)}`);

  console.log("\nCalling the Responses API with require_approval: 'always'...");
  const alwaysResult = await callResponsesApi(key.accessToken, 'always', serverLabel);
  console.log(`  [${alwaysResult.outcome}] ${JSON.stringify(alwaysResult)}`);

  console.log("\nCalling again with require_approval: 'never'...");
  const neverResult = await callResponsesApi(key.accessToken, 'never', serverLabel);
  console.log(`  [${neverResult.outcome}] ${JSON.stringify(neverResult)}`);

  confirmBlocked(alwaysResult, "tool server status 'disabled'", { status: 403 });
  confirmBlocked(neverResult, "tool server status 'disabled'", { status: 403 });

  const alwaysViolations = alwaysResult.body?.violations ?? [];
  const neverViolations = neverResult.body?.violations ?? [];
  confirmEquals(alwaysViolations.includes('tool_server_disabled'), true, "'always' should be blocked by tool_server_disabled");
  confirmEquals(neverViolations.includes('tool_server_disabled'), true, "'never' should carry tool_server_disabled too");
  confirmEquals(
    neverViolations.includes('tool_server_auto_approval_disabled') && !alwaysViolations.includes('tool_server_auto_approval_disabled'),
    true,
    "tool_server_auto_approval_disabled should apply to 'never' only",
  );
  console.log("Confirmed: pending servers are blocked; require_approval: 'never' adds its own violation.");

  // ---------------------------------------------------------------------------
  // 2. Active server and definition review
  // ---------------------------------------------------------------------------
  console.log('\nRegistering an active tool server with applyImmediately: true...');
  const activeServerLabel = `example-mcp-active-${suffix}`;
  const { createLLMGatewayToolServer: toolServer2 } = await graphql(
    `mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
      createLLMGatewayToolServer(input: $input) { id name status }
    }`,
    {
      input: {
        name: activeServerLabel,
        serverType: 'mcp',
        serverUrl: 'https://mcp.github.example/v1',
        status: 'active',
        allowedToolNames: ['create_issue', 'list_issues'],
        applyImmediately: true,
      },
    },
  );
  console.log(`  tool server ${toolServer2.id} - status: ${toolServer2.status}`);
  confirmEquals(toolServer2.status, 'active', "applyImmediately: true should register the tool server as 'active'");

  console.log('\nCreating a policy for the active tool server...');
  const activePolicy = await createPolicy({
    name: `mcp-active-policy-${suffix}`,
    mode: 'enforce', budgetMode: 'hard_fast',
    allowedProviders: ['vertex_ai'], allowedModels: [MODELS.default],
    allowedToolServers: [activeServerLabel],
  });
  const activeKey = await createVirtualKey({ name: `vk-mcp-active-${suffix}`, teamId: 'Platform AI', appId: `${appId}-active`, environment: 'dev' });
  await createBinding({ policyId: activePolicy.id, teamId: 'Platform AI', appId: `${appId}-active`, environment: 'dev', priority: 10, acknowledgeOverlap: true });
  console.log(`Minted active key ${activeKey.id}, bound.`);

  console.log('\nSending live chat completion with tool "create_issue" (v1 schema)...');
  const toolV1 = {
    type: 'function',
    function: {
      name: 'create_issue',
      description: 'Create a new issue on GitHub repository',
      parameters: {
        type: 'object',
        properties: {
          title: { type: 'string', description: 'The issue title' },
          body: { type: 'string', description: 'The issue description' },
        },
        required: ['title'],
      },
      mcp_server: activeServerLabel,
    },
  };

  const call1 = await callChatCompletions(activeKey.accessToken, toolV1, 'Please create an issue titled Bug in login');
  console.log(`  Gateway inference response: status = ${call1.status}`);
  confirmEquals(call1.status, 200, 'Live inference with registered active tool server should succeed (200)');

  console.log('  Waiting for tool definition ingestion...');
  const defs1 = await waitForToolDefinitions(
    toolServer2.id,
    (res) => res.definitions?.some((d) => d.toolName === 'create_issue'),
  );
  const approvedV1 = defs1.definitions.find((d) => d.toolName === 'create_issue' && d.status === 'approved');
  confirmEquals(Boolean(approvedV1), true, 'First definition should be registered as the approved baseline');
  console.log('  Confirmed: first tool definition registered as the approved baseline.');

  console.log('\nSending live chat completion with MODIFIED schema for "create_issue" (v2 schema: added priority)...');
  const toolV2 = {
    type: 'function',
    function: {
      name: 'create_issue',
      description: 'Create a new issue on GitHub repository with priority tags',
      parameters: {
        type: 'object',
        properties: {
          title: { type: 'string', description: 'The issue title' },
          body: { type: 'string', description: 'The issue description' },
          priority: { type: 'string', enum: ['low', 'medium', 'high', 'critical'] },
        },
        required: ['title', 'priority'],
      },
      mcp_server: activeServerLabel,
    },
  };

  const call2 = await callChatCompletions(activeKey.accessToken, toolV2, 'Create urgent issue with priority high');
  console.log(`  Gateway inference response: status = ${call2.status}`);
  confirmEquals(call2.status, 200, 'Changed tool-definition request should succeed');

  console.log('  Waiting for the schema change to appear in the review queue...');
  const defs2 = await waitForToolDefinitions(
    toolServer2.id,
    (res) => res.definitions?.some((d) => d.toolName === 'create_issue' && d.status === 'pending'),
  );
  const pendingV2 = defs2.definitions.find((d) => d.toolName === 'create_issue' && d.status === 'pending');
  confirmEquals(Boolean(pendingV2), true, 'Modified tool schema should be recorded as pending review (drift)');
  console.log('  Confirmed: changed definition recorded as pending review.');

  console.log('\nReviewing pending definition -> decision: approve...');
  const reviewed = await reviewToolDefinition(toolServer2.id, 'create_issue', pendingV2.definitionSha256, 'approve');
  console.log(`  Review mutation result: status = "${reviewed.status}"`);

  const defs3 = await queryToolDefinitions(toolServer2.id);
  const currentApproved = defs3.definitions.find((d) => d.definitionSha256 === pendingV2.definitionSha256);
  const supersededOld = defs3.definitions.find((d) => d.definitionSha256 === approvedV1.definitionSha256);
  confirmEquals(currentApproved?.status, 'approved', 'New definition should transition to approved');
  confirmEquals(supersededOld?.status, 'superseded', 'Old definition should transition to superseded');
  console.log('  Confirmed: review state transitioned new definition to "approved" and superseded the prior definition.');

  // ---------------------------------------------------------------------------
  // 3. Provider-called MCP checks
  // ---------------------------------------------------------------------------
  console.log('\nTesting security & policy enforcement guardrails...');

  // Provider-called MCP server access is checked before inference.
  const rogueCall = await callResponsesApi(activeKey.accessToken, 'always', 'unregistered-server', ['create_issue']);
  confirmEquals(rogueCall.status, 403, 'Unregistered tool server should be blocked with 403');
  confirmEquals(rogueCall.body?.violations?.includes('tool_server_unknown'), true, 'Should include tool_server_unknown violation');
  console.log('  Confirmed: tool referencing unregistered server blocked with tool_server_unknown.');

  const disallowedCall = await callResponsesApi(activeKey.accessToken, 'always', activeServerLabel, ['drop_database']);
  confirmEquals(disallowedCall.status, 403, 'Disallowed tool name should be blocked with 403');
  confirmEquals(disallowedCall.body?.violations?.includes('tool_server_tool_not_allowed'), true, 'Should include tool_server_tool_not_allowed violation');
  console.log('  Confirmed: disallowed tool name blocked with tool_server_tool_not_allowed.');

  console.log(`\nEvidence: Audit tab (${CONSOLE.audit}) shows tool definition review audit events; Policies tab (${CONSOLE.policies}) shows registered tool servers and observed tool lists.`);
}

main().catch((err) => {
  console.error('mcp-tool-governance failed:', err);
  process.exitCode = 1;
});
