import { config, USER_AGENT } from './config.mjs';

// Thin GraphQL helper used by every example to create its own policy,
// binding, and virtual key with the shared ai:admin key. Nothing here is
// Cloptima-internal - createLLMGatewayPolicy/Binding/Key are the same public
// mutations any customer's own tooling would call.
export async function graphql(query, variables) {
  const response = await fetch(`${config.baseUrl}/graphql`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'user-agent': USER_AGENT,
      authorization: `Bearer ${config.aiAdminKey}`,
    },
    body: JSON.stringify({ query, variables }),
  });
  const body = await response.json();
  if (body.errors?.length) {
    throw new Error(`GraphQL error (http ${response.status}): ${JSON.stringify(body.errors)}`);
  }
  return body.data;
}

export async function createPolicy(input) {
  const data = await graphql(
    `mutation CreatePolicy($input: LLMGatewayPolicyInput!) { createLLMGatewayPolicy(input: $input) { id name } }`,
    { input },
  );
  return data.createLLMGatewayPolicy;
}

export async function createVirtualKey(input) {
  const data = await graphql(
    `mutation CreateKey($input: CreateLLMGatewayKeyInput!) {
      createLLMGatewayKey(input: $input) { id accessToken tokenPrefix expiresAt }
    }`,
    { input },
  );
  return data.createLLMGatewayKey;
}

export async function createBinding(input) {
  const data = await graphql(
    `mutation CreateBinding($input: LLMGatewayPolicyBindingInput!) {
      createLLMGatewayPolicyBinding(input: $input) { id }
    }`,
    { input },
  );
  return data.createLLMGatewayPolicyBinding;
}

// Generic governance queue - any policy/budget/route change that needs
// sign-off before it takes effect goes through this same queue,
// not a scenario-specific approval queue. Shared by approval-workflow.mjs and
// semantic-cache-enforce.mjs (the latter reads it to show the auto-queued
// entry a semanticCacheMode: 'enforce' policy creates).
export async function createLLMGatewayApproval(input) {
  const data = await graphql(
    `mutation CreateApproval($input: LLMGatewayApprovalInput!) {
      createLLMGatewayApproval(input: $input) {
        id approvalType status requiredApproverRole targetId requestedAt
      }
    }`,
    { input },
  );
  return data.createLLMGatewayApproval;
}

export async function listLLMGatewayApprovals({ status, limit, offset } = {}) {
  const data = await graphql(
    `query ListApprovals($status: String, $limit: Int, $offset: Int) {
      llmGatewayApprovals(status: $status, limit: $limit, offset: $offset) {
        id approvalType status targetId requestedAt requiredApproverRole
      }
    }`,
    { status, limit, offset },
  );
  return data.llmGatewayApprovals;
}
