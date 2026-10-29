"""Thin REST helper used by every example to create its own policy, binding,
and virtual key with the shared ai:admin key. Nothing here is
Cloptima-internal - these are the same public REST endpoints any customer's
own tooling would call. Request bodies and response fields use the API's
snake_case field names.

`query` values that are None are skipped; a list value is sent as repeated
keys (unit_type=a&unit_type=b). Every POST carries a JSON body (`{}` when the
operation takes none): the API requires a JSON content type on every POST. A
204 answer returns None. Any other non-2xx answer raises AdminApiError, whose
`status_code` is the HTTP status and whose message carries the API error
`{"error": {"code", "message"}}`.
"""

from typing import Any, Optional

import requests

from . import config


class AdminApiError(RuntimeError):
    def __init__(self, message: str, status_code: int):
        super().__init__(message)
        self.status_code = status_code


def admin_api(method: str, path: str, query: Optional[dict] = None, body: Optional[dict] = None) -> Any:
    if not config.AI_ADMIN_KEY:
        raise RuntimeError("This example creates governance resources and needs CLOPTIMA_AI_ADMIN_KEY. Add it to .env (see .env.example).")
    headers = {"user-agent": config.USER_AGENT, "authorization": f"Bearer {config.AI_ADMIN_KEY}"}
    if body is None and method == "POST":
        body = {}
    if body is not None:
        headers["content-type"] = "application/json"
    response = requests.request(
        method,
        f"{config.BASE_URL}{path}",
        headers=headers,
        params={key: value for key, value in (query or {}).items() if value is not None},
        json=body,
        timeout=30,
    )
    if response.status_code == 204:
        return None
    if not response.ok:
        detail = response.text
        try:
            error = response.json().get("error") or {}
            if error.get("code") or error.get("message"):
                detail = f"{error.get('code')}: {error.get('message')}"
        except (ValueError, AttributeError):
            pass  # Not JSON: report the raw text.
        raise AdminApiError(f"{method} {path} failed (HTTP {response.status_code}): {detail}", response.status_code)
    return response.json() if response.content else None


def create_policy(policy: dict) -> dict:
    return admin_api("POST", "/v1/llm/policies", body=policy)


def create_guardrail_profile(profile: dict) -> dict:
    return admin_api("POST", "/v1/llm/guardrail-profiles", body=profile)


# The response's `access_token` is the virtual key the application uses.
def create_virtual_key(key: dict) -> dict:
    return admin_api("POST", "/v1/llm/gateway-keys", body=key)


def create_binding(binding: dict) -> dict:
    return admin_api("POST", "/v1/llm/policy-bindings", body=binding)


# Generic governance queue - any policy, budget, or tool-server change that
# needs sign-off before it takes effect goes through this same queue, not a
# scenario-specific approval queue.
def create_approval(approval: dict) -> dict:
    return admin_api("POST", "/v1/llm/approvals", body=approval)


# Returns {items, next_cursor}. Query: status, search, limit, cursor.
def list_approvals(query: Optional[dict] = None) -> dict:
    return admin_api("GET", "/v1/llm/approvals", query=query)


# Returns {agent_session_id, items, next_cursor}: one item per request in the
# agent session. Query: session_id (required), window, limit, cursor.
def list_session_steps(query: dict) -> dict:
    return admin_api("GET", "/v1/llm/sessions/steps", query=query)


# Returns {agent_session_id, items, next_cursor}: the session's retained
# trace records, each with its integrity `verification`.
def list_session_records(query: dict) -> dict:
    return admin_api("GET", "/v1/llm/sessions/records", query=query)
