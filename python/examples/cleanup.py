"""Automated cleanup script for Cloptima AI gateway example resources.

WARNING: This script permanently deletes every AI gateway policy, policy
binding, guardrail profile, registered tool server, and ROI calibration in
the authenticated account. It also archives price sheets, revokes all
active virtual keys and provider credentials, and rejects all pending
approvals.

Intended for sandbox, testing, or demo environments to clean up resources
before or after evaluating example scripts.

Usage:
    python -m examples.cleanup
    python -m examples.cleanup --force
"""

import os
import sys
from urllib.parse import quote

from lib import config
from lib.gateway_admin import AdminApiError, admin_api


PAGE_SIZE = 100


def list_all(path: str, query=None) -> list:
    """Reads every page of a cursor-paged list."""
    items, cursor = [], None
    while True:
        page = admin_api("GET", path, query={**(query or {}), "limit": PAGE_SIZE, "cursor": cursor})
        items.extend(page["items"])
        cursor = page.get("next_cursor")
        if not cursor:
            return items


def list_active_keys() -> list:
    """Virtual keys page by offset."""
    items = []
    offset = 0
    while True:
        page = admin_api("GET", "/v1/llm/gateway-keys", query={"status": "active", "limit": PAGE_SIZE, "offset": offset})
        items.extend(page["items"])
        if not page["has_more"]:
            return items
        offset += PAGE_SIZE


def item_path(path: str, item: dict) -> str:
    return f"{path}/{quote(item['id'], safe='')}"


def remove(path: str):
    return lambda item: admin_api("DELETE", item_path(path, item))


# Each step removes one resource type. Order matters: bindings go before the
# policies they reference, and policies go before the guardrail profiles they
# reference.
STEPS = [
    {
        "label": "policy binding(s)",
        "list": lambda: list_all("/v1/llm/policy-bindings"),
        "run": remove("/v1/llm/policy-bindings"),
    },
    {
        "label": "policy/policies",
        "list": lambda: list_all("/v1/llm/policies"),
        "run": remove("/v1/llm/policies"),
    },
    {
        "label": "guardrail profile(s)",
        "list": lambda: list_all("/v1/llm/guardrail-profiles"),
        "run": remove("/v1/llm/guardrail-profiles"),
    },
    {
        "label": "tool server(s)",
        "list": lambda: list_all("/v1/llm/tool-servers"),
        "run": remove("/v1/llm/tool-servers"),
    },
    {
        "label": "active virtual key(s)",
        "verb": "Revoked",
        "list": list_active_keys,
        "run": remove("/v1/llm/gateway-keys"),
    },
    {
        "label": "active provider credential(s)",
        "verb": "Revoked",
        "list": lambda: list_all("/v1/llm/provider-credentials", {"status": "active"}),
        "run": remove("/v1/llm/provider-credentials"),
    },
    {
        "label": "pending approval request(s)",
        "verb": "Rejected",
        "plan_gated": True,  # llm_approval_workflows
        "list": lambda: list_all("/v1/llm/approvals", {"status": "pending"}),
        "run": lambda item: admin_api(
            "POST",
            f"{item_path('/v1/llm/approvals', item)}/review",
            body={"decision": "reject", "reason": "Automated cleanup"},
        ),
    },
    {
        "label": "active price sheet(s)",
        "verb": "Archived",
        "plan_gated": True,  # llm_contract_pricing
        "list": lambda: [sheet for sheet in list_all("/v1/llm/pricing/sheets") if sheet.get("status") != "archived"],
        "run": lambda item: admin_api("POST", f"{item_path('/v1/llm/pricing/sheets', item)}/archive"),
    },
    {
        "label": "ROI calibration(s)",
        # This list is not paged.
        "list": lambda: admin_api("GET", "/v1/llm/roi/calibrations")["items"],
        "run": remove("/v1/llm/roi/calibrations"),
    },
]


def list_step(step: dict):
    """A plan-gated step whose list call answers HTTP 403 is not on this plan:
    it is skipped for the rest of the run. Any other list error fails the run."""
    try:
        return step["list"]()
    except AdminApiError as err:
        if not step.get("plan_gated") or err.status_code != 403:
            raise
        print(f"Skipped {step['label']}: not available on this plan.")
        return None


def main():
    is_force = (
        "--force" in sys.argv
        or "-y" in sys.argv
        or os.environ.get("CI") == "true"
        or os.environ.get("NONINTERACTIVE") == "true"
    )

    print("=" * 80)
    print("  WARNING: AI Gateway Account Resource Cleanup")
    print("=" * 80)
    print("  This script permanently removes ALL AI gateway policies, policy bindings,")
    print("  guardrail profiles, tool servers, and ROI calibrations; archives ALL price")
    print("  sheets; revokes ALL virtual keys and provider credentials; and rejects ALL")
    print("  pending approvals in the account associated with the configured")
    print("  CLOPTIMA_AI_ADMIN_KEY.")
    print()
    print(f"  Target Gateway: {config.BASE_URL}")
    print()
    print("  Do NOT run this script in an account with production policies or live traffic.")
    print("  Use --force or -y to bypass interactive confirmation in automated workflows.")
    print("=" * 80 + "\n")

    if sys.stdin.isatty() and not is_force:
        try:
            answer = input("Are you sure you want to clean up all gateway resources? (y/N): ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nCleanup aborted.")
            sys.exit(0)
        if answer not in ("y", "yes"):
            print("Cleanup aborted.")
            sys.exit(0)
        print()

    cleaned_any = False
    previous_fingerprint = None
    steps = STEPS
    while True:
        print("Checking for remaining gateway resources..." if cleaned_any else "Fetching existing gateway resources...")
        plan = []
        for step in steps:
            found = list_step(step)
            if found is not None:
                plan.append({**step, "found": found})
        steps = plan
        remaining = sum(len(step["found"]) for step in plan)
        if remaining == 0:
            print("\nCleanup completed successfully." if cleaned_any else "Account is already clean. No resources to delete.")
            return

        fingerprint = "|".join(sorted(
            f"{step['label']}:{item['id']}"
            for step in plan
            for item in step["found"]
        ))
        if fingerprint == previous_fingerprint:
            raise RuntimeError("cleanup made no progress; one or more resources remain")
        previous_fingerprint = fingerprint

        print("Found:")
        for step in plan:
            print(f"  - {len(step['found'])} {step['label']}")
        print()

        failures = 0
        for step in plan:
            done = 0
            for item in step["found"]:
                try:
                    step["run"](item)
                    done += 1
                except Exception as err:
                    failures += 1
                    item_name = item.get("name") or item.get("display_name") or item["id"]
                    print(f"  Failed on {step['label']} {item_name}: {err}", file=sys.stderr)
            print(f"✓ {step.get('verb', 'Deleted')} {done}/{len(step['found'])} {step['label']}")

        if failures:
            raise RuntimeError(f"{failures} resource(s) could not be removed")
        cleaned_any = True


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print(f"\nCleanup failed: {err}", file=sys.stderr)
        sys.exit(1)
