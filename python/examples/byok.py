"""Bring-Your-Own-Key (BYOK): Enterprise Credential Governance

Demonstrates how to route inference requests through customer-owned provider
credentials while maintaining unified policy enforcement, telemetry, and audit trails.

Prerequisites:
- Set CLOPTIMA_PROVIDER_CREDENTIAL_ID in .env (if already registered in Console), OR
- Set PROVIDER_API_KEY in .env (OpenAI API key) to register a test credential.

Run standalone:
  python -m examples.byok
"""
import os

from lib import config, gateway_admin
from lib.access import get_access
from lib.client import openai_client
from lib.config import CONSOLE


def resolve_provider_credential_id() -> str:
    cred_id = os.environ.get("CLOPTIMA_PROVIDER_CREDENTIAL_ID")
    if cred_id:
        print(f"Using registered provider credential ID: {cred_id}")
        return cred_id

    api_key = os.environ.get("PROVIDER_API_KEY")
    if not api_key:
        raise RuntimeError(
            "This example requires your own provider API key. "
            "Set PROVIDER_API_KEY (or CLOPTIMA_PROVIDER_CREDENTIAL_ID) in .env (see .env.example)."
        )

    suffix = config.run_suffix()
    name = f"byok-demo-{suffix}"
    print(f"Registering customer-owned OpenAI credential ({name})...")
    data = gateway_admin.graphql(
        """mutation CreateCred($input: CreateLLMProviderCredentialInput!) {
          createLLMProviderCredential(input: $input) { id displayName provider }
        }""",
        {"input": {"displayName": name, "provider": "openai", "apiKey": api_key}},
    )
    created = data["createLLMProviderCredential"]
    print(f"Registered credential: {created['id']}")
    return created["id"]


def main() -> None:
    print("=== Bring-Your-Own-Key (BYOK): Enterprise Credential Routing ===\n")

    credential_id = resolve_provider_credential_id()

    # Governance setup: the policy this application runs under. Platform admins normally
    # create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
    # points at a key whose policy already matches.
    access = get_access(
        app="byok-demo",
        policy={
            "name": "byok-policy",
            "mode": "enforce",
            "budgetMode": "hard",
            "allowedProviders": ["openai"],
            "allowedModels": ["openai/gpt-4o-mini"],
        },
    )

    # Application code: client points at Cloptima gateway with virtual key and passes
    # the provider credential ID header.
    client = openai_client(
        access["virtual_key"],
        default_headers={"x-cloptima-provider-credential-id": credential_id},
    )

    print("Sending query through Cloptima Gateway under BYOK credential...")
    try:
        response = client.chat.completions.create(
            model="openai/gpt-4o-mini",
            messages=[
                {"role": "system", "content": "You are an enterprise AI architect."},
                {
                    "role": "user",
                    "content": "Summarize the advantage of Bring-Your-Own-Key (BYOK) architecture for enterprise compliance in two sentences.",
                },
            ],
            temperature=0.7,
        )

        content = response.choices[0].message.content or ""
        print("\n--- Model Response ---")
        print(content.strip())

        print("\n--- BYOK Execution Telemetry ---")
        print(f"Model: {response.model}")
        if response.usage:
            print(
                f"Tokens: prompt={response.usage.prompt_tokens}, "
                f"completion={response.usage.completion_tokens}, total={response.usage.total_tokens}"
            )
        print(f"Billed To: Customer Provider Account (via credential {credential_id})")
        print("Governance Status: Authorized, policy validated, audit record preserved")
    except Exception as err:
        print(f"Enterprise BYOK request failed: {err}")

    print(f"\nReview credential usage and logs in Cloptima Console: {CONSOLE['credentials']}")


if __name__ == "__main__":
    main()
