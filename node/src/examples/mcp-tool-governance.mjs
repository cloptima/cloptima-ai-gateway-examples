/**
 * Enterprise Agent with Governed MCP Tools
 *
 * Demonstrates how an AI agent calls tools through Cloptima's MCP governance layer,
 * and how the application handles tool servers and tools that policy does not allow.
 *
 * Pattern:
 * 1. Governance setup: register tool servers and bind a policy that allows one of them.
 *    A newly registered server is created `disabled` until it is reviewed.
 * 2. Case 1: Agent calls an allowed tool on an approved server -> admitted.
 * 3. Case 2: Agent references an unregistered server -> blocked with HTTP 403.
 * 4. Case 3: Agent requests a tool the server does not allow -> blocked with HTTP 403.
 *
 * Needs CLOPTIMA_AI_ADMIN_KEY (registers tool servers and a policy).
 *
 * Run standalone:
 *   node src/examples/mcp-tool-governance.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { provisionApp } from '../lib/access.mjs';
import { graphql, listLLMGatewayApprovals } from '../lib/gatewayAdmin.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE, runSuffix } from '../lib/config.mjs';

const CREATE_TOOL_SERVER = `mutation CreateToolServer($input: LLMGatewayToolServerInput!) {
  createLLMGatewayToolServer(input: $input) { id name status }
}`;

// Sends a Responses API request that attaches an MCP server, and returns the violations
// the gateway reports when it blocks the request.
async function callWithMcpServer(client, serverLabel, allowedTools) {
  try {
    await client.post('/responses', {
      body: {
        model: MODELS.default,
        input: 'Run the requested maintenance task.',
        tools: [{ type: 'mcp', server_label: serverLabel, allowed_tools: allowedTools, require_approval: 'always' }],
      },
    });
    return { blocked: false, violations: [] };
  } catch (err) {
    if (err.status === 403) return { blocked: true, violations: err.error?.violations || [] };
    throw err;
  }
}

async function main() {
  console.log('=== Enterprise Agent: MCP Tool Governance ===\n');
  const suffix = runSuffix();

  // --- Governance setup (admin) -------------------------------------------------------------
  // Platform admins normally register tool servers once in the Console or through the API.
  console.log('Registering a new tool server (awaiting security review)...');
  const { createLLMGatewayToolServer: pendingServer } = await graphql(CREATE_TOOL_SERVER, {
    input: {
      name: `mcp-pending-${suffix}`,
      serverType: 'mcp',
      serverUrl: 'https://mcp.example.com/v1',
      status: 'active',
      allowedToolNames: ['search', 'lookup'],
    },
  });
  console.log(`  ${pendingServer.name}: status "${pendingServer.status}" until an admin approves the registration.`);

  const pending = await listLLMGatewayApprovals({ status: 'pending', limit: 50 });
  const registration = pending.find((a) => a.approvalType === 'mcp_tool_server_registration' && a.targetId === pendingServer.id);
  if (registration) console.log(`  Review queued as approval ${registration.id} (${CONSOLE.audit}).`);

  console.log('\nRegistering a reviewed tool server with applyImmediately: true...');
  const serverLabel = `mcp-github-${suffix}`;
  const { createLLMGatewayToolServer: activeServer } = await graphql(CREATE_TOOL_SERVER, {
    input: {
      name: serverLabel,
      serverType: 'mcp',
      serverUrl: 'https://mcp.github.example/v1',
      status: 'active',
      allowedToolNames: ['create_issue', 'list_issues'],
      applyImmediately: true,
    },
  });
  console.log(`  ${activeServer.name}: status "${activeServer.status}"`);

  const { virtualKey } = await provisionApp({
    app: 'mcp-agent-demo',
    policy: {
      name: 'mcp-agent-policy',
      mode: 'enforce',
      budgetMode: 'hard_fast',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
      allowedToolServers: [serverLabel], // the agent may only use this tool server
    },
  });

  // --- Application code ----------------------------------------------------------------------
  const client = openaiClient(virtualKey);

  console.log('\n--- Case 1: Allowed Tool on an Approved Server ---');
  const response = await client.chat.completions.create({
    model: MODELS.default,
    messages: [{ role: 'user', content: 'Open an issue titled "Update documentation" on GitHub.' }],
    tools: [
      {
        type: 'function',
        function: {
          name: 'create_issue',
          description: 'Create a new issue on a GitHub repository',
          parameters: {
            type: 'object',
            properties: {
              title: { type: 'string', description: 'The issue title' },
              body: { type: 'string', description: 'The issue description' },
            },
            required: ['title'],
          },
          mcp_server: serverLabel,
        },
      },
    ],
  });
  const toolCall = response.choices[0]?.message?.tool_calls?.[0];
  console.log('Gateway status: Allowed (HTTP 200)');
  console.log(toolCall
    ? `Model selected tool: ${toolCall.function.name}(${toolCall.function.arguments})`
    : `Model response: ${response.choices[0]?.message?.content?.trim()}`);

  console.log('\n--- Case 2: Unregistered Tool Server ---');
  const unknown = await callWithMcpServer(client, 'unregistered-server', ['create_issue']);
  console.log(unknown.blocked
    ? `Blocked before inference (HTTP 403). Violations: ${unknown.violations.join(', ')}`
    : 'Admitted unexpectedly.');

  console.log('\n--- Case 3: Tool Not on the Server Allowlist ---');
  const disallowed = await callWithMcpServer(client, serverLabel, ['drop_database']);
  console.log(disallowed.blocked
    ? `Blocked before inference (HTTP 403). Violations: ${disallowed.violations.join(', ')}`
    : 'Admitted unexpectedly.');
  if (disallowed.blocked) {
    console.log('Application action: abort the tool call and return control to the user.');
  }

  console.log(`\nEvidence in Cloptima Console:`);
  console.log(`  - Audit trail: ${CONSOLE.audit}`);
  console.log(`  - Registered tool servers & policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
