"""A growing multi-turn conversation - the shape a coding assistant or any
chat agent actually produces: each turn resends the full message history
(a large, mostly-unchanged prefix) plus one new small exchange. This is
provider-side prompt caching, not Cloptima's own exact/semantic response
cache (see exact_semantic_cache.py) - there is no cache config on the policy
below, no repeated identical prompt, and no client-side toggle for it either.
When the provider recognizes a repeated prefix above its own minimum size,
it reuses the cached portion instead of reprocessing it, and reports how
many tokens came from cache versus fresh input on that call's usage.

The first turn has nothing to reuse yet - only later turns should show a
nonzero cached-token count as the shared history grows past the provider's
caching threshold.
Run standalone from python/:
    python -m examples.conversation_prompt_caching
"""

import json

import requests

from lib import config
from lib.gateway_admin import create_binding, create_policy, create_virtual_key
from lib.models import MODEL_DEFAULT

MAX_TOKENS_PER_CALL = 80

# A stable "project context" block a coding assistant would keep resending
# as system context on every turn. Real enough in size to matter: providers
# apply automatic prompt caching only above their own minimum prefix size
# (commonly in the low thousands of tokens), so a too-short stable prefix
# here would never show cached-token evidence no matter how many turns
# follow - this needs to be sized like a real system prompt, not a toy one,
# even though each per-turn question below stays a single short sentence.
PROJECT_CONTEXT = """You are a coding assistant working inside an existing repository.

Project conventions:
- Language: Python 3.11, type hints required on all public functions.
- Formatting: black, line length 100.
- Tests: pytest, one test file per module under tests/, table-driven where practical.
- Error handling: raise typed exceptions from a shared `errors.py`, never bare Exception.
- Logging: structured logging via `logging.getLogger(__name__)`, no print statements.
- Dependency policy: stdlib first, existing pinned dependencies second, new dependencies
  require a one-line justification comment at the import site.
- Currency values are always `Decimal`, never `float`.
- Timestamps are always timezone-aware UTC, never naive `datetime`.
- Prefer composition over inheritance for service classes.
- Keep functions under 40 lines; extract helpers rather than nesting deeply.
- Public functions get a one-line docstring describing behavior, not implementation.
- Avoid premature abstraction - three call sites before extracting a shared helper.

Repository layout:
- `app/models/` - typed dataclasses for domain entities: Order, Customer, Invoice, Payment,
  Shipment, Product, Warehouse, Inventory, Discount, Refund, Subscription, Plan, Address,
  TaxRate, Currency, Coupon, LoyaltyAccount, ReturnRequest, SupportTicket, Vendor,
  PurchaseOrder, StockAdjustment, PriceList, Contract, Invoice, CreditNote.
- `app/services/` - business logic, one service class per bounded context, dependency-injected
  repositories, no direct database access from services. Existing services: OrderService,
  CustomerService, InvoiceService, PaymentService, ShipmentService, InventoryService,
  DiscountService, RefundService, SubscriptionService, TaxService, LoyaltyService,
  SupportTicketService, VendorService, PurchaseOrderService, PricingService, ContractService.
- `app/repositories/` - one repository per aggregate root, thin wrappers over a shared
  connection pool, no business logic. Naming: `<Entity>Repository`, one file per entity.
- `app/api/` - FastAPI routers, request/response Pydantic models kept separate from domain
  dataclasses, one router per resource, versioned under `/api/v1/`.
- `app/workers/` - background job handlers, idempotent by design, safe to retry, each reads
  from a named queue and writes a completion record before acking.
- `app/events/` - domain event definitions and the in-process event bus; services publish,
  workers subscribe, no direct service-to-service calls for cross-context side effects.
- `tests/` - mirrors `app/` structure exactly, one test module per source module.

Domain rules already established:
- An `Order` cannot transition to `shipped` without at least one `Payment` in `captured` state.
- A `Refund` always references the original `Payment` it reverses; partial refunds are allowed
  but the sum of refunds on a payment can never exceed the original captured amount.
- `Invoice` totals are recalculated from line items on every read, never cached on the row,
  to avoid drift between stored totals and the underlying line items.
- `Subscription` renewal is handled by a worker, not a request-time side effect, so a slow
  payment provider never blocks an API response.
- `Inventory` adjustments always go through `StockAdjustment` records for audit history;
  nothing decrements a stock count directly.
- `Coupon` and `Discount` are separate concepts: a `Coupon` is a customer-facing redeemable
  code, a `Discount` is the underlying rule it activates; a coupon always references exactly
  one discount, but a discount can be activated by more than one coupon or by no coupon at all.
- `SupportTicket` records are never deleted, only status-transitioned, for compliance history.
- `Vendor` and `PurchaseOrder` live in the same bounded context as `Inventory` but are modeled
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
""" + "\n".join(
    f"- `app/services/module_{i:03d}.py` handles bounded-context concern #{i}: validates inputs "
    f"against the corresponding Pydantic schema, delegates persistence to its paired "
    f"repository, publishes a domain event on state change, and never imports another "
    f"service module directly - cross-context calls always go through the event bus."
    for i in range(80)
)

FOLLOW_UP_QUESTIONS = [
    "In one sentence, where should a new `Coupon` domain type live?",
    "In one sentence, should a repository ever call a service class?",
    "In one sentence, how should a background job in app/workers/ handle a transient DB error?",
    "In one sentence, what type should an invoice total field use?",
]


def call_chat(virtual_key: str, model: str, messages: list, label: str) -> dict:
    response = requests.post(
        f"{config.BASE_URL}/v1/ai/chat/completions",
        headers={
            "content-type": "application/json",
            "user-agent": config.USER_AGENT,
            "authorization": f"Bearer {virtual_key}",
            "x-cloptima-feature": "conversation_prompt_caching_probe",
        },
        json={"model": model, "max_tokens": MAX_TOKENS_PER_CALL, "messages": messages},
        timeout=30,
    )
    try:
        body = response.json()
    except ValueError:
        body = None
    usage = (body or {}).get("usage") if response.status_code == 200 else None
    return {"label": label, "status": response.status_code, "usage": usage, "body": body}


def main():
    suffix = config.run_suffix()
    app_id = f"conv-cache-{suffix}"

    print("Creating a policy with no cache config at all (default off) - any cached-token "
          "evidence below comes from the provider's own prompt caching, not a Cloptima "
          "cache feature...")
    policy = create_policy({
        "name": f"conversation-prompt-caching-{suffix}",
        "mode": "enforce", "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"], "allowedModels": [MODEL_DEFAULT],
    })
    key = create_virtual_key({"name": f"vk-conv-cache-{suffix}", "teamId": "Platform AI", "appId": app_id, "environment": "dev"})
    create_binding({"policyId": policy["id"], "teamId": "Platform AI", "appId": app_id, "environment": "dev", "priority": 10, "acknowledgeOverlap": True})
    print(f"Minted key {key['id']}, bound.\n")

    print("Sending a growing conversation - each turn resends the full history (system "
          "context + every prior exchange) plus one new short question, the same shape a "
          "coding assistant produces...\n")

    messages = [{"role": "system", "content": PROJECT_CONTEXT}]
    results = []
    for i, question in enumerate(FOLLOW_UP_QUESTIONS):
        messages.append({"role": "user", "content": question})
        result = call_chat(key["accessToken"], MODEL_DEFAULT, messages, f"turn-{i + 1}")
        results.append(result)
        usage = result["usage"] or {}
        cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
        prompt_tokens = usage.get("prompt_tokens", "?")
        print(f"  [turn-{i + 1}] status={result['status']} prompt_tokens={prompt_tokens} cached_tokens={cached}")
        reply = ""
        if result["status"] == 200 and result["body"] and result["body"].get("choices"):
            reply = result["body"]["choices"][0]["message"]["content"]
        messages.append({"role": "assistant", "content": reply})

    print(
        "\nTurn 1 has nothing to reuse yet, so cached_tokens should read 0 there. From turn 2 "
        "onward, the repeated system context plus prior turns should start showing up as "
        "cached_tokens instead of full-price prompt tokens - propagation is not always "
        "immediate, so a slow start on turn 2 that catches up by turn 3-4 is expected, not a "
        "problem with this example."
    )
    print(f"Evidence: Explorer tab ({config.CONSOLE['spend']}) - filter by app \"{app_id}\" - shows cached-token counts and the discounted per-request cost for each turn above.")
    print(json.dumps(results, indent=2, default=str))


if __name__ == "__main__":
    main()
