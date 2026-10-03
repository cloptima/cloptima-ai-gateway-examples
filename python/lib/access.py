from typing import Any, Dict, Optional

from . import config, gateway_admin

TEAM = "AI Engineering"
ENVIRONMENT = "development"


def provision_app(
    app: str,
    policy: Dict[str, Any],
    guardrail_profile: Optional[Dict[str, Any]] = None,
    team: str = TEAM,
    environment: str = ENVIRONMENT,
) -> Dict[str, Any]:
    """Governance setup: creates the policy (and optional guardrail profile), a
    virtual key, and the binding that attaches the policy to that key's
    team/app/environment. Platform teams normally do this once in the Console,
    Terraform, or CI. Each example passes its policy definition inline so the
    configuration being demonstrated is visible next to the application code.
    Requires CLOPTIMA_AI_ADMIN_KEY.
    """
    suffix = config.run_suffix()
    app_id = f"{app}-{suffix}"

    profile = None
    if guardrail_profile:
        profile_input = dict(guardrail_profile)
        profile_input["name"] = f"{guardrail_profile['name']}-{suffix}"
        profile = gateway_admin.create_guardrail_profile(profile_input)

    policy_input = dict(policy)
    policy_input["name"] = f"{policy['name']}-{suffix}"
    if profile:
        policy_input["guardrailProfileId"] = profile["id"]

    created_policy = gateway_admin.create_policy(policy_input)
    key = gateway_admin.create_virtual_key(
        {"name": f"vk-{app_id}", "teamId": team, "appId": app_id, "environment": environment}
    )
    gateway_admin.create_binding(
        {
            "policyId": created_policy["id"],
            "teamId": team,
            "appId": app_id,
            "environment": environment,
            "priority": 10,
            "acknowledgeOverlap": True,
        }
    )

    return {
        "virtual_key": key["accessToken"],
        "app_id": app_id,
        "team_id": team,
        "environment": environment,
        "policy": created_policy,
        "profile": profile,
        "suffix": suffix,
    }


def get_access(
    app: str,
    policy: Dict[str, Any],
    guardrail_profile: Optional[Dict[str, Any]] = None,
    team: str = TEAM,
    environment: str = ENVIRONMENT,
) -> Dict[str, Any]:
    """Returns the virtual key the application code should use.
    - CLOPTIMA_VIRTUAL_KEY set: use it as-is. The key must already be bound to a
      policy equivalent to the one in the example's governance setup.
    - Otherwise: run the governance setup with CLOPTIMA_AI_ADMIN_KEY.
    """
    if config.VIRTUAL_KEY:
        print(
            "Using CLOPTIMA_VIRTUAL_KEY. The key should be bound to a policy like the governance setup in this file.\n"
        )
        return {"virtual_key": config.VIRTUAL_KEY, "provisioned": False}

    if not config.AI_ADMIN_KEY:
        raise RuntimeError(
            "Set CLOPTIMA_VIRTUAL_KEY to use an existing key, or CLOPTIMA_AI_ADMIN_KEY to let this example create its own policy and key (see .env.example)."
        )

    result = provision_app(
        app=app,
        policy=policy,
        guardrail_profile=guardrail_profile,
        team=team,
        environment=environment,
    )
    result["provisioned"] = True
    return result
