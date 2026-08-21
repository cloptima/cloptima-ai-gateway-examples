// Maps demo-friendly field names to the managed-gateway attribution headers
// used by these examples. The global environment guide lists telemetry-only
// dimensions separately. A key configured with team/app/environment does not
// need those values repeated on every call.
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
