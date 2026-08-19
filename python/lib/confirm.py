"""Programmatic assertion helpers for Cloptima managed AI gateway examples.

The policy, binding, and virtual key an example creates are the entire
contract. These confirm the gateway honoured that contract and stop the
script with a specific message when it did not, so a run where enforcement
quietly stopped working can never print as a success.

Nothing here asks the gateway to enforce anything. No header, flag, or
counter is sent - the only input is the configuration registered above.
"""

import json


def _detail(result):
    if not isinstance(result, dict):
        return f"result={result!r}"
    status = f" status={result.get('status')}" if result.get("status") is not None else ""
    reason = result.get("reason")
    reason_str = ""
    if reason is not None:
        reason_str = f" reason={reason if isinstance(reason, str) else json.dumps(reason, default=str)}"
    return f"outcome={result.get('outcome', 'undefined')}{status}{reason_str}"


def _mentions(result, violation):
    if not isinstance(result, dict):
        return str(violation).lower() in str(result).lower()
    reason = result.get("reason") or result.get("body") or result.get("error")
    text = reason if isinstance(reason, str) else json.dumps(reason or "", default=str)
    return str(violation).lower() in text.lower()


def confirm_allowed(result, what):
    outcome = result.get("outcome") if isinstance(result, dict) else None
    if outcome != "allowed":
        raise RuntimeError(f"{what}: expected this call to be served, got {_detail(result)}")
    return result


def confirm_blocked(result, what, status=None, violation=None):
    outcome = result.get("outcome") if isinstance(result, dict) else None
    if outcome != "blocked":
        raise RuntimeError(f"{what}: expected the gateway to block this call, got {_detail(result)}")
    if status is not None and result.get("status") != status:
        raise RuntimeError(f"{what}: expected HTTP {status}, got {_detail(result)}")
    if violation and not _mentions(result, violation):
        raise RuntimeError(f'{what}: expected the block to name "{violation}", got {_detail(result)}')
    return result


def confirm_cap_stopped(results, what, status=None, violation=None, expected_allowed=None):
    """For caps that admit traffic up to a threshold and then stop it.

    Returns a dict with allowed_count and blocked result, so the example reports
    the real number rather than assuming the cap fired.
    """
    index = -1
    for i, res in enumerate(results):
        outcome = res.get("outcome") if isinstance(res, dict) else None
        if outcome != "allowed":
            index = i
            break

    if index == -1:
        raise RuntimeError(
            f"{what}: expected the cap to stop a call, but all {len(results)} were served. "
            "The limit is set on the policy and these calls ran under a key bound to it."
        )

    confirm_blocked(results[index], what, status=status, violation=violation)
    if expected_allowed is not None and index != expected_allowed:
        raise RuntimeError(f"{what}: expected {expected_allowed} calls to be served before the cap, got {index}")
    return {"allowed_count": index, "blocked": results[index]}


def confirm_equals(actual, expected, what):
    if actual != expected:
        raise RuntimeError(f"{what}: expected {expected!r}, got {actual!r}")
    return actual
