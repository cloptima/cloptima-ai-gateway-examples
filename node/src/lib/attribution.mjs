// Maps demo-friendly field names to the x-cloptima-* attribution headers the
// managed gateway reads (see docs/ENVIRONMENT.md for the full header table).
export function attributionHeaders({
  teamId,
  appId,
  environment,
  feature,
  workflowId,
  agentSessionId,
  agentRunId,
  parentExecutionId,
  toolName,
  toolCallId,
  businessTransactionType,
  businessTransactionId,
  businessTransactionUnitCount,
  businessOutcomeStatus,
  businessValueCents,
} = {}) {
  const fields = {
    'x-cloptima-team': teamId,
    'x-cloptima-app': appId,
    'x-cloptima-environment': environment,
    'x-cloptima-feature': feature,
    'x-cloptima-workflow': workflowId,
    'x-cloptima-agent-session-id': agentSessionId,
    'x-cloptima-agent-run-id': agentRunId,
    'x-cloptima-parent-execution-id': parentExecutionId,
    'x-cloptima-tool-name': toolName,
    'x-cloptima-tool-call-id': toolCallId,
    'x-cloptima-business-transaction-type': businessTransactionType,
    'x-cloptima-business-transaction-id': businessTransactionId,
    'x-cloptima-business-transaction-unit-count': businessTransactionUnitCount,
    'x-cloptima-business-outcome-status': businessOutcomeStatus,
    'x-cloptima-business-value-cents': businessValueCents,
  };

  const headers = {};
  for (const [key, value] of Object.entries(fields)) {
    if (value !== undefined && value !== null) headers[key] = String(value);
  }
  return headers;
}
