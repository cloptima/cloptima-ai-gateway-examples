#!/usr/bin/env bash
# A growing multi-turn conversation - the shape a coding assistant or any
# chat agent actually produces: each turn resends the full message history
# (a large, mostly-unchanged prefix) plus one new small exchange. This is
# provider-side prompt caching, not Cloptima's own exact/semantic response
# cache (see exact-semantic-cache.sh) - there is no cache config on the policy
# below, no repeated identical prompt, and no client-side toggle for it either.
# When the provider recognizes a repeated prefix above its own minimum size,
# it reuses the cached portion instead of reprocessing it, and reports how
# many tokens came from cache versus fresh input on that call's usage.
#
# The first turn has nothing to reuse yet - only later turns should show a
# nonzero cached-token count as the shared history grows past the provider's
# caching threshold.
#
# Auth: CLOPTIMA_VIRTUAL_KEY (runs only the application code) or CLOPTIMA_AI_ADMIN_KEY
# (also creates the policy and key). See .env.example.
# Run standalone: ./conversation-prompt-caching.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
load_env

MODEL_DEFAULT="vertex_ai/gemini-3.5-flash-lite"
MAX_TOKENS_PER_CALL=80

# A stable "project context" block a coding assistant would keep resending
# as system context on every turn. Real enough in size to matter: providers
# apply automatic prompt caching only above their own minimum prefix size
# (commonly in the low thousands of tokens), so a too-short stable prefix
# here would never show cached-token evidence no matter how many turns
# follow - this needs to be sized like a real system prompt, not a toy one,
# even though each per-turn question below stays a single short sentence.
PROJECT_CONTEXT="You are a coding assistant working inside an existing repository.

Project conventions:
- Language: Python 3.11, type hints required on all public functions.
- Formatting: black, line length 100.
- Tests: pytest, one test file per module under tests/, table-driven where practical.
- Error handling: raise typed exceptions from a shared \`errors.py\`, never bare Exception.
- Logging: structured logging via \`logging.getLogger(__name__)\`, no print statements.
- Dependency policy: stdlib first, existing pinned dependencies second, new dependencies
  require a one-line justification comment at the import site.
- Currency values are always \`Decimal\`, never \`float\`.
- Timestamps are always timezone-aware UTC, never naive \`datetime\`.
- Prefer composition over inheritance for service classes.
- Keep functions under 40 lines; extract helpers rather than nesting deeply.
- Public functions get a one-line docstring describing behavior, not implementation.
- Avoid premature abstraction - three call sites before extracting a shared helper.

Repository layout:
- \`app/models/\` - typed dataclasses for domain entities: Order, Customer, Invoice, Payment,
  Shipment, Product, Warehouse, Inventory, Discount, Refund, Subscription, Plan, Address,
  TaxRate, Currency, Coupon, LoyaltyAccount, ReturnRequest, SupportTicket, Vendor,
  PurchaseOrder, StockAdjustment, PriceList, Contract, Invoice, CreditNote.
- \`app/services/\` - business logic, one service class per bounded context, dependency-injected
  repositories, no direct database access from services. Existing services: OrderService,
  CustomerService, InvoiceService, PaymentService, ShipmentService, InventoryService,
  DiscountService, RefundService, SubscriptionService, TaxService, LoyaltyService,
  SupportTicketService, VendorService, PurchaseOrderService, PricingService, ContractService.
- \`app/repositories/\` - one repository per aggregate root, thin wrappers over a shared
  connection pool, no business logic. Naming: \`<Entity>Repository\`, one file per entity.
- \`app/api/\` - FastAPI routers, request/response Pydantic models kept separate from domain
  dataclasses, one router per resource, versioned under \`/api/v1/\`.
- \`app/workers/\` - background job handlers, idempotent by design, safe to retry, each reads
  from a named queue and writes a completion record before acking.
- \`app/events/\` - domain event definitions and the in-process event bus; services publish,
  workers subscribe, no direct service-to-service calls for cross-context side effects.
- \`tests/\` - mirrors \`app/\` structure exactly, one test module per source module.

Domain rules already established:
- An \`Order\` cannot transition to \`shipped\` without at least one \`Payment\` in \`captured\` state.
- A \`Refund\` always references the original \`Payment\` it reverses; partial refunds are allowed
  but the sum of refunds on a payment can never exceed the original captured amount.
- \`Invoice\` totals are recalculated from line items on every read, never cached on the row,
  to avoid drift between stored totals and the underlying line items.
- \`Subscription\` renewal is handled by a worker, not a request-time side effect, so a slow
  payment provider never blocks an API response.
- \`Inventory\` adjustments always go through \`StockAdjustment\` records for audit history;
  nothing decrements a stock count directly.
- \`Coupon\` and \`Discount\` are separate concepts: a \`Coupon\` is a customer-facing redeemable
  code, a \`Discount\` is the underlying rule it activates; a coupon always references exactly
  one discount, but a discount can be activated by more than one coupon or by no coupon at all.
- \`SupportTicket\` records are never deleted, only status-transitioned, for compliance history.
- \`Vendor\` and \`PurchaseOrder\` live in the same bounded context as \`Inventory\` but are modeled
  separately since a vendor relationship long outlives any individual purchase order.

Review checklist a change should satisfy before it's considered done:
- New public functions have type hints and a one-line docstring.
- New domain rules are reflected in a repository-layer constraint where practical, not just
  enforced in the service layer.
- New background jobs are idempotent and have a matching test that calls the handler twice.
- New API endpoints have both a happy-path and a validation-failure test.
- No new dependency without the one-line justification comment at the import site.

When asked to write or modify code, follow these conventions exactly, keep answers to one
short paragraph unless code is explicitly requested, and flag any convention you had to break
and why.

Additional module notes for reference:
$(for i in $(seq 0 79); do
  printf -- "- \`app/services/module_%03d.py\` handles bounded-context concern #%d: validates inputs against the corresponding Pydantic schema, delegates persistence to its paired repository, publishes a domain event on state change, and never imports another service module directly - cross-context calls always go through the event bus.\n" "$i" "$i"
done)"

echo "=== Multi-Turn Assistant: Provider Prompt Caching ==="
echo ""

# Governance setup: a policy with no cache config at all (default off), so any cached-token
# evidence below comes from the provider's own prompt caching, not a Cloptima cache feature.
# Platform admins normally create it once in the Console, Terraform, or CI. Skipped when
# CLOPTIMA_VIRTUAL_KEY points at a key whose policy already matches.
get_access "coding-assistant-demo" "$(jq -n --arg model "$MODEL_DEFAULT" '{
  name: "coding-assistant-policy", mode: "enforce", budgetMode: "hard_fast",
  allowedProviders: ["vertex_ai"], allowedModels: [$model]}')"

# Application code: each turn resends the full message history plus one new short question.
echo "Sending a growing conversation - each turn resends the full history (system context + every prior exchange) plus one new short question..."
echo ""

FOLLOW_UP_QUESTIONS=(
  "In one sentence, where should a new \`Coupon\` domain type live?"
  "In one sentence, should a repository ever call a service class?"
  "In one sentence, how should a background job in app/workers/ handle a transient DB error?"
  "In one sentence, what type should an invoice total field use?"
)

MESSAGES=$(jq -n --arg system "$PROJECT_CONTEXT" '[{"role": "system", "content": $system}]')
for i in "${!FOLLOW_UP_QUESTIONS[@]}"; do
  QUESTION="${FOLLOW_UP_QUESTIONS[$i]}"
  MESSAGES=$(echo "$MESSAGES" | jq --arg q "$QUESTION" '. + [{"role": "user", "content": $q}]')
  BODY=$(jq -n --arg model "$MODEL_DEFAULT" --argjson maxTokens "$MAX_TOKENS_PER_CALL" --argjson messages "$MESSAGES" \
    '{model: $model, max_tokens: $maxTokens, messages: $messages}')
  HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/ai/chat/completions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $USER_AGENT" \
    -H "x-cloptima-feature: conversation_prompt_caching_probe" \
    -d "$BODY")
  if [ "$HTTP_CODE" = "200" ]; then
    PROMPT_TOKENS=$(jq -r '.usage.prompt_tokens // "?"' "$RESP_BODY_FILE")
    CACHED_TOKENS=$(jq -r '.usage.prompt_tokens_details.cached_tokens // 0' "$RESP_BODY_FILE")
    REPLY=$(jq -r '.choices[0].message.content // ""' "$RESP_BODY_FILE")
    echo "  [turn-$((i + 1))] status=$HTTP_CODE prompt_tokens=$PROMPT_TOKENS cached_tokens=$CACHED_TOKENS"
    MESSAGES=$(echo "$MESSAGES" | jq --arg reply "$REPLY" '. + [{"role": "assistant", "content": $reply}]')
  else
    echo "  [turn-$((i + 1))] failed (HTTP $HTTP_CODE)"
    describe_block
    break
  fi
done

echo ""
echo "Turn 1 has nothing to reuse yet, so cached_tokens should read 0 there. From turn 2"
echo "onward, the repeated system context plus prior turns should start showing up as"
echo "cached_tokens instead of full-price prompt tokens - propagation is not always"
echo "immediate, so a slow start on turn 2 that catches up by turn 3-4 is expected, not a"
echo "problem with this example."

echo ""
echo "--- Case 2: Anthropic Messages API (Explicit cache_control) ---"
ANTHROPIC_BODY=$(jq -n --arg model "$MODEL_DEFAULT" --arg prompt "$PROJECT_CONTEXT" --arg q "${FOLLOW_UP_QUESTIONS[0]}" \
  '{model: $model, max_tokens: 80, system: [{type: "text", text: $prompt, cache_control: {type: "ephemeral"}}], messages: [{role: "user", content: $q}]}')
HTTP_CODE=$(curl -sS -o "$RESP_BODY_FILE" -w '%{http_code}' -X POST "$BASE_URL/v1/messages" \
  -H "x-api-key: $ACCESS_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $USER_AGENT" \
  -d "$ANTHROPIC_BODY")
if [ "$HTTP_CODE" = "200" ]; then
  INPUT_TOKENS=$(jq -r '.usage.input_tokens // "?"' "$RESP_BODY_FILE")
  CREATED=$(jq -r '.usage.cache_creation_input_tokens // 0' "$RESP_BODY_FILE")
  READ=$(jq -r '.usage.cache_read_input_tokens // 0' "$RESP_BODY_FILE")
  echo "  [Anthropic Messages] status=$HTTP_CODE input_tokens=$INPUT_TOKENS (created: $CREATED, read: $READ)"
else
  echo "  [Anthropic Messages] request returned HTTP $HTTP_CODE"
fi

echo ""
echo "Review prompt caching savings in Cloptima Console:"
echo "  - Spend Explorer: $CONSOLE_SPEND"
