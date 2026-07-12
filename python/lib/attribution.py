def attribution_headers(
    team_id=None,
    app_id=None,
    environment=None,
    feature=None,
    workflow_id=None,
    agent_session_id=None,
    agent_run_id=None,
    parent_execution_id=None,
    tool_name=None,
    tool_call_id=None,
    business_transaction_type=None,
    business_transaction_id=None,
    business_transaction_unit_count=None,
    business_outcome_status=None,
    business_value_cents=None,
):
    """Maps demo-friendly field names to the x-cloptima-* attribution headers
    the managed gateway reads (see docs/ENVIRONMENT.md for the full header table).
    """
    fields = {
        "x-cloptima-team": team_id,
        "x-cloptima-app": app_id,
        "x-cloptima-environment": environment,
        "x-cloptima-feature": feature,
        "x-cloptima-workflow": workflow_id,
        "x-cloptima-agent-session-id": agent_session_id,
        "x-cloptima-agent-run-id": agent_run_id,
        "x-cloptima-parent-execution-id": parent_execution_id,
        "x-cloptima-tool-name": tool_name,
        "x-cloptima-tool-call-id": tool_call_id,
        "x-cloptima-business-transaction-type": business_transaction_type,
        "x-cloptima-business-transaction-id": business_transaction_id,
        "x-cloptima-business-transaction-unit-count": business_transaction_unit_count,
        "x-cloptima-business-outcome-status": business_outcome_status,
        "x-cloptima-business-value-cents": business_value_cents,
    }
    return {key: str(value) for key, value in fields.items() if value is not None}
