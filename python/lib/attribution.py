def attribution_headers(
    team_id=None,
    app_id=None,
    environment=None,
    feature=None,
    workflow_id=None,
    business_transaction_type=None,
    business_transaction_id=None,
    business_transaction_unit_count=None,
    business_outcome_status=None,
    business_outcome_success=None,
    business_value_cents=None,
):
    """Maps demo-friendly field names to the x-cloptima-* attribution headers
    the managed gateway reads (see docs/ENVIRONMENT.md for the full header
    table). These affect only cost/ROI reporting, never which requests are
    allowed or blocked - team_id/app_id/environment are only meaningful here
    for a key that wasn't already minted scoped to them; a key created with
    its own teamId/appId/environment doesn't need them repeated per call.
    """
    fields = {
        "x-cloptima-team": team_id,
        "x-cloptima-app": app_id,
        "x-cloptima-environment": environment,
        "x-cloptima-feature": feature,
        "x-cloptima-workflow": workflow_id,
        "x-cloptima-business-transaction-type": business_transaction_type,
        "x-cloptima-business-transaction-id": business_transaction_id,
        "x-cloptima-business-transaction-unit-count": business_transaction_unit_count,
        "x-cloptima-business-outcome-status": business_outcome_status,
        "x-cloptima-business-outcome-success": business_outcome_success,
        "x-cloptima-business-value-cents": business_value_cents,
    }
    return {key: str(value) for key, value in fields.items() if value is not None}
