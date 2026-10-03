"""Thin GraphQL helper used by every example to create its own policy,
binding, and virtual key with the shared ai:admin key. Nothing here is
Cloptima-internal - createLLMGatewayPolicy/Binding/Key are the same public
mutations any customer's own tooling would call.
"""

from typing import Optional

import requests

from . import config


def graphql(query: str, variables: dict) -> dict:
    response = requests.post(
        f"{config.BASE_URL}/graphql",
        headers={
            "content-type": "application/json",
            "user-agent": config.USER_AGENT,
            "authorization": f"Bearer {config.AI_ADMIN_KEY}",
        },
        json={"query": query, "variables": variables},
        timeout=30,
    )
    body = response.json()
    if body.get("errors"):
        raise RuntimeError(f"GraphQL error (http {response.status_code}): {body['errors']}")
    return body["data"]


def create_policy(input_data: dict) -> dict:
    data = graphql(
        "mutation CreatePolicy($input: LLMGatewayPolicyInput!) { createLLMGatewayPolicy(input: $input) { id name } }",
        {"input": input_data},
    )
    return data["createLLMGatewayPolicy"]


def create_guardrail_profile(input_data: dict) -> dict:
    data = graphql(
        """mutation CreateGuardrailProfile($input: LLMGuardrailProfileInput!) {
          createLLMGuardrailProfile(input: $input) { id name publishedVersion { version } }
        }""",
        {"input": input_data},
    )
    return data["createLLMGuardrailProfile"]


def create_virtual_key(input_data: dict) -> dict:
    data = graphql(
        """mutation CreateKey($input: CreateLLMGatewayKeyInput!) {
          createLLMGatewayKey(input: $input) { id accessToken tokenPrefix expiresAt }
        }""",
        {"input": input_data},
    )
    return data["createLLMGatewayKey"]


def create_binding(input_data: dict) -> dict:
    data = graphql(
        """mutation CreateBinding($input: LLMGatewayPolicyBindingInput!) {
          createLLMGatewayPolicyBinding(input: $input) { id }
        }""",
        {"input": input_data},
    )
    return data["createLLMGatewayPolicyBinding"]


# Generic governance queue - any policy/budget/route change that needs
# sign-off before it takes effect goes through this same queue, not a
# scenario-specific approval queue. Shared by approval_workflow.py and
# semantic_cache_enforce.py (the latter reads it to show the auto-queued
# entry a semanticCacheMode: 'enforce' policy creates).
def create_llm_gateway_approval(input_data: dict) -> dict:
    data = graphql(
        """mutation CreateApproval($input: LLMGatewayApprovalInput!) {
          createLLMGatewayApproval(input: $input) {
            id approvalType status requiredApproverRole targetId requestedAt
          }
        }""",
        {"input": input_data},
    )
    return data["createLLMGatewayApproval"]


def list_llm_gateway_approvals(
    status: Optional[str] = None, limit: Optional[int] = None, offset: Optional[int] = None
) -> list:
    data = graphql(
        """query ListApprovals($status: String, $limit: Int, $offset: Int) {
          llmGatewayApprovals(status: $status, limit: $limit, offset: $offset) {
            id approvalType status targetId requestedAt requiredApproverRole
          }
        }""",
        {"status": status, "limit": limit, "offset": offset},
    )
    return data["llmGatewayApprovals"]


def get_llm_agent_session(session_id: str, window: Optional[str] = None) -> dict:
    data = graphql(
        """query GetAgentSession($sessionId: String!, $window: String) {
          llmAgentSession(sessionId: $sessionId, window: $window) {
            agentSessionId
            steps {
              requestId
              provider
              model
              status
              inputTokens
              outputTokens
              costUsd
              requestedToolNames
              responseToolNames
              traceSha256
            }
          }
        }""",
        {"sessionId": session_id, "window": window},
    )
    return data["llmAgentSession"]


def get_llm_agent_session_records(session_id: str, window: Optional[str] = None) -> dict:
    data = graphql(
        """query GetAgentSessionRecords($sessionId: String!, $window: String) {
          llmAgentSessionRecords(sessionId: $sessionId, window: $window) {
            records {
              requestId
              verification
            }
          }
        }""",
        {"sessionId": session_id, "window": window},
    )
    return data["llmAgentSessionRecords"]
