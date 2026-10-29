/**
 * Multi-Turn Coding Assistant: Provider Prompt Caching
 *
 * Demonstrates how multi-turn chat applications benefit from provider-side
 * prompt caching on large recurring system prompts and conversation history.
 *
 * Pattern:
 * 1. Initialize official SDKs (OpenAI and Anthropic) with Cloptima gateway URL & virtual key.
 * 2. Case 1: OpenAI automatic prefix caching (prompt_tokens_details.cached_tokens).
 * 3. Case 2: Anthropic explicit breakpoint prompt caching (cache_control: { type: 'ephemeral' }).
 *
 * Run standalone:
 *   node src/examples/conversation-prompt-caching.mjs
 */
import { openaiClient, anthropicClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

// Providers apply automatic prompt caching only above their own minimum prefix size
// (commonly 1,024+ tokens). A stable, realistic system prompt prefix ensures prompt caching activates.
const PROJECT_CONTEXT = `You are a coding assistant working inside an existing repository.

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
` + Array.from({ length: 80 }, (_, i) => {
  const padded = String(i).padStart(3, '0');
  return `- \`app/services/module_${padded}.py\` handles bounded-context concern #${i}: validates inputs against the corresponding Pydantic schema, delegates persistence to its paired repository, publishes a domain event on state change, and never imports another service module directly - cross-context calls always go through the event bus.`;
}).join('\n');

const FOLLOW_UP_QUESTIONS = [
  'Where are typed domain entities located in this project?',
  'What is the project policy regarding currency calculations and float types?',
  'What logging convention should I follow when writing a new service class?',
];

async function main() {
  console.log('=== Multi-Turn Assistant: Provider Prompt Caching ===\n');

  // Governance setup: the policy this application runs under. Platform admins normally
  //    create it once in the Console, Terraform, or CI. It is skipped when CLOPTIMA_VIRTUAL_KEY
  //    points at a key whose policy already matches.
  const access = await getAccess({
    app: 'coding-assistant-demo',
    policy: {
      name: 'coding-assistant-policy',
      mode: 'enforce',
      budget_mode: 'hard',
      allowed_providers: ['vertex_ai'],
      allowed_models: [MODELS.default],
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  console.log('Starting multi-turn conversation with persistent codebase context...\n');

  const messages = [{ role: 'system', content: PROJECT_CONTEXT }];

  for (let i = 0; i < FOLLOW_UP_QUESTIONS.length; i++) {
    const question = FOLLOW_UP_QUESTIONS[i];
    messages.push({ role: 'user', content: question });

    console.log(`[Turn ${i + 1}] User: "${question}"`);

    try {
      const response = await client.chat.completions.create({
        model: MODELS.default,
        max_tokens: 80,
        messages,
      });

      const reply = response.choices[0]?.message?.content?.trim() || '';
      messages.push({ role: 'assistant', content: reply });

      const usage = response.usage || {};
      const promptTokens = usage.prompt_tokens ?? 0;
      const cachedTokens = usage.prompt_tokens_details?.cached_tokens ?? 0;

      console.log(`  Assistant: "${reply.slice(0, 70)}..."`);
      console.log(`  Tokens: ${promptTokens} total prompt tokens (${cachedTokens} cached from previous turns)\n`);
    } catch (err) {
      console.error(`  Turn ${i + 1} error:`, err.message);
    }
  }

  // --- Case 2: Anthropic Messages API with Explicit Prompt Caching ---
  console.log('--- Case 2: Anthropic Messages API (Explicit cache_control) ---');
  const anthropic = anthropicClient(access.virtualKey);

  try {
    const anthropicResponse = await anthropic.messages.create({
      model: MODELS.default,
      max_tokens: 80,
      system: [
        {
          type: 'text',
          text: PROJECT_CONTEXT,
          cache_control: { type: 'ephemeral' },
        },
      ],
      messages: [{ role: 'user', content: FOLLOW_UP_QUESTIONS[0] }],
    });

    const anthropicReply = anthropicResponse.content?.[0]?.text?.trim() || '';
    const anthropicUsage = anthropicResponse.usage || {};
    console.log(`User: "${FOLLOW_UP_QUESTIONS[0]}"`);
    console.log(`Assistant: "${anthropicReply.slice(0, 70)}..."`);
    console.log(`Tokens: ${anthropicUsage.input_tokens} input (created cache: ${anthropicUsage.cache_creation_input_tokens || 0}, read from cache: ${anthropicUsage.cache_read_input_tokens || 0})\n`);
  } catch (err) {
    console.log('Anthropic prompt caching check:', err.message, '\n');
  }

  console.log(`Review prompt caching savings in Cloptima Console:`);
  console.log(`  - Spend Explorer: ${CONSOLE.spend}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
