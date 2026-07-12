"""Uses the ai:admin key to bring your own provider credential: create it,
test it, then route one managed-gateway call through it so your own key gets
Cloptima's governance/attribution/telemetry layer on top - billed to your own
provider account, not Cloptima's managed-credits wallet.
Requires PROVIDER_API_KEY (your own OpenAI-compatible key) in .env.
Run standalone from python/:
    python -m examples.byok
"""

import json
import os

import requests

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key, graphql


def _required_provider_key() -> str:
    value = os.environ.get("PROVIDER_API_KEY")
    if not value:
        raise RuntimeError("Missing required env var PROVIDER_API_KEY - set your own provider API key in .env.")
    return value


def main():
    provider_api_key = _required_provider_key()
    suffix = config.run_suffix()
    app_id = f"byok-{suffix}"

    print("Creating a provider credential (BYOK)...")
    created = graphql(
        """mutation CreateCredential($input: CreateLLMProviderCredentialInput!) {
          createLLMProviderCredential(input: $input) { id provider displayName }
        }""",
        {"input": {"provider": "openai", "displayName": f"byok-openai-{suffix}", "apiKey": provider_api_key}},
    )
    credential_id = created["createLLMProviderCredential"]["id"]
    print(f"Created credential {credential_id} ({created['createLLMProviderCredential']['displayName']})")

    print("Testing the credential against a model...")
    tested = graphql(
        """mutation TestCredential($id: ID!, $input: TestLLMProviderCredentialInput) {
          testLLMProviderCredential(id: $id, input: $input) { id provider displayName }
        }""",
        {"id": credential_id, "input": {"model": "gpt-4o-mini"}},
    )
    print("Credential test result:", json.dumps(tested["testLLMProviderCredential"], indent=2))

    print("Creating a policy allowing the BYOK provider/model and minting a key...")
    policy = create_policy({
        "name": f"byok-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["openai"], "allowedModels": ["openai/gpt-4o-mini"],
    })
    key = create_virtual_key({"name": f"vk-byok-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound. Making one managed-gateway call routed through the BYOK credential...\n")

    response = requests.post(
        f"{config.BASE_URL}/v1/ai/chat/completions",
        headers={
            "content-type": "application/json",
            "user-agent": config.USER_AGENT,
            "authorization": f"Bearer {key['accessToken']}",
            "x-cloptima-provider-credential-id": credential_id,
            "x-cloptima-team": "Platform AI",
            "x-cloptima-app": app_id,
            "x-cloptima-environment": "dev",
        },
        json={
            "model": "openai/gpt-4o-mini",
            "messages": [{"role": "user", "content": "In one sentence, confirm this call used a bring-your-own-key provider credential."}],
        },
        timeout=30,
    )
    print(f"Gateway response status={response.status_code}")
    print(json.dumps(response.json(), indent=2))

    print("\nThis call is billed to your own provider account, not Cloptima's managed-credit wallet.")
    print(f"Evidence: Credentials tab ({config.CONSOLE['credentials']}) shows the provider credential just created; Audit tab ({config.CONSOLE['audit']}) and Explorer tab ({config.CONSOLE['spend']}) confirm attribution/telemetry are still captured even though spend is BYOK.")


if __name__ == "__main__":
    main()
