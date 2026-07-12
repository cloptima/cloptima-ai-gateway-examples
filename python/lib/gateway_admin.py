"""Thin GraphQL helper used by every example to create its own policy,
binding, and virtual key with the shared ai:admin key. Nothing here is
Cloptima-internal - createLLMGatewayPolicy/Binding/Key are the same public
mutations any customer's own tooling would call.
"""

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


def create_policy(input: dict) -> dict:
    data = graphql(
        "mutation CreatePolicy($input: LLMGatewayPolicyInput!) { createLLMGatewayPolicy(input: $input) { id name } }",
        {"input": input},
    )
    return data["createLLMGatewayPolicy"]


def create_virtual_key(input: dict) -> dict:
    data = graphql(
        """mutation CreateKey($input: CreateLLMGatewayKeyInput!) {
          createLLMGatewayKey(input: $input) { id accessToken tokenPrefix expiresAt }
        }""",
        {"input": input},
    )
    return data["createLLMGatewayKey"]


def create_binding(input: dict) -> dict:
    data = graphql(
        """mutation CreateBinding($input: LLMGatewayPolicyBindingInput!) {
          createLLMGatewayPolicyBinding(input: $input) { id }
        }""",
        {"input": input},
    )
    return data["createLLMGatewayPolicyBinding"]
