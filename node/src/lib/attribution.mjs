// Maps demo-friendly field names to the x-cloptima-* attribution headers the
// managed gateway reads (see docs/ENVIRONMENT.md for the full header table).
// These affect only cost/ROI reporting, never which requests are allowed or
// blocked - teamId/appId/environment are only meaningful here for a key that
// wasn't already minted scoped to them; a key created with its own
// teamId/appId/environment doesn't need them repeated per call.
export function attributionHeaders({
  teamId,
  appId,
  environment,
  feature,
  workflowId,
  businessTransactionType,
  businessTransactionId,
  businessTransactionUnitCount,
  businessOutcomeStatus,
  businessOutcomeSuccess,
  businessValueCents,
} = {}) {
  const fields = {
    'x-cloptima-team': teamId,
    'x-cloptima-app': appId,
    'x-cloptima-environment': environment,
    'x-cloptima-feature': feature,
    'x-cloptima-workflow': workflowId,
    'x-cloptima-business-transaction-type': businessTransactionType,
    'x-cloptima-business-transaction-id': businessTransactionId,
    'x-cloptima-business-transaction-unit-count': businessTransactionUnitCount,
    'x-cloptima-business-outcome-status': businessOutcomeStatus,
    'x-cloptima-business-outcome-success': businessOutcomeSuccess,
    'x-cloptima-business-value-cents': businessValueCents,
  };

  const headers = {};
  for (const [key, value] of Object.entries(fields)) {
    if (value !== undefined && value !== null) headers[key] = String(value);
  }
  return headers;
}
