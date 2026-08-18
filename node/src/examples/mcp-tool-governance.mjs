// MCP / tool-server governance: register a tool server, allow it (and only
// it) on a policy, then exercise the OpenAI Responses API's remote-MCP-tool
// path through the managed proxy.
//
// A newly registered tool server is always 'disabled', even if the request
// asks for status: 'active' - registration overrides it and auto-queues an
// mcp_tool_server_registration approval in the same generic
// governance queue as semantic-cache-enforce.mjs's auto-queued
// semantic_cache_enforce entry. Reviewing that approval is the same
// second-identity step this repo never scripts (see approval-workflow.mjs),
// so both calls below are expected to be blocked by tool_server_disabled -
// this example isn't demonstrating an
// allowed call, it's demonstrating the governance gate and that
// require_approval: 'never' is enforced as its own, separate rule on top of
// it: the 'never' call's violations list carries an additional
// tool_server_auto_approval_disabled entry the 'always' call doesn't get,
// proving that rule holds independently of (and would still apply once) the
// tool server is reviewed and made active.
//
// At the end, a second tool server is registered with applyImmediately: true
// to show the alternative: since this key already qualifies to review this
// itself, that one activates right away instead of starting 'disabled'.
//
// Uses raw fetch rather than the openai SDK for these two calls: the SDK's
// APIError only surfaces the JSON body's top-level `error` string and drops
// the sibling `reason`/`violations` fields the gateway actually returns,
// which is exactly the detail this example needs to show.
// Run standalone:
//   node src/examples/mcp-tool-governance.mjs
import { config, runSuffix, CONSOLE, USER_AGENT } from '../lib/config.mjs';
import { graphql, createPolicy, createVirtualKey, createBinding, listLLMGatewayApprovals } from '../lib/gatewayAdmin.mjs';
import { MODELS } from '../lib/models.mjs';

async function callResponsesApi(accessToken, requireApproval, serverLabel) {
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
      tools: [{ type: 'mcp', server_label: serverLabel, allowed_tools: ['search'], require_approval: requireApproval }],
    }),
  });
  const body = await response.json();
  const outcome = response.status === 200 ? 'allowed' : (response.status >= 400 && response.status < 500 ? 'blocked' : 'error');
  return { outcome, status: response.status, body };
}

async function main() {
  const suffix = runSuffix();
  const appId = `mcp-tool-governance-${suffix}`;
  const serverLabel = `example-mcp-server-${suffix}`;

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
      "  This is the one step this script does NOT do: reviewing it requires a second privileged identity in the "
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
        // Must match the binding above (team + app + environment) so the
        // simulation resolves against the same policy the real calls below
        // will run under.
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

  console.log(
    "\nExpected: both calls are blocked (403) because the tool server above is still 'disabled' pending review - "
    + "'always' is blocked by tool_server_disabled alone. 'never' carries that SAME violation plus an additional "
    + 'tool_server_auto_approval_disabled entry the \'always\' call does not get - proving the never-auto-approve '
    + 'rule is enforced as its own, independent check that would still apply even after this tool server is '
    + 'reviewed and made active.',
  );
  console.log(`Evidence: Audit tab (${CONSOLE.audit}) - filter by app "${appId}" for both records and the pending tool-server-registration approval; Policies tab (${CONSOLE.policies}) shows the tool server registration and allowedToolServers config.`);

  console.log('\nRegistering a second tool server, this time with applyImmediately: true...');
  const { createLLMGatewayToolServer: toolServer2 } = await graphql(
    `mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
      createLLMGatewayToolServer(input: $input) { id name status }
    }`,
    {
      input: {
        name: `example-mcp-server-immediate-${suffix}`,
        serverType: 'mcp',
        serverUrl: 'https://example.com/mcp',
        status: 'active',
        allowedToolNames: ['search', 'lookup'],
        applyImmediately: true,
      },
    },
  );
  console.log(`  tool server ${toolServer2.id} - status: ${toolServer2.status}`);
  console.log(
    "Expected: status 'active' right away - applyImmediately: true meant this registration was approved and "
    + 'activated in this same call, with no separate review step and no tool_server_disabled block.',
  );
}

main().catch((err) => {
  console.error('mcp-tool-governance failed:', err);
  process.exitCode = 1;
});
