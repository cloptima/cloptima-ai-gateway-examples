# Cache and policy behavior

## There is no client-side cache toggle

Exact-cache and semantic-cache behavior is entirely server-side and policy-driven. A request cannot ask for caching to be enabled, disabled, or bypassed - there is no header or body field for it. What determines caching:

- Whether the policy bound to your virtual key has `exact_cache_enabled` / `semantic_cache_enabled` turned on, and in which mode (`exact_cache_mode` / `semantic_cache_mode`: `off`, `observe`, or `enforce`).
- Route, model, and content-class allow-lists on the policy.
- Payload size, streaming, and sensitive-data-detection rules on the policy.

If you send the exact same prompt repeatedly (as the `exact-semantic-cache` example does) and the bound policy has exact-cache enabled, you should see the effect in the console (lower latency, cache-hit evidence in Explorer/Audit) even though nothing in the example code asks for it explicitly.

## Attribution headers can affect cache scope, indirectly

A policy-level setting called `exact_cache_key_scope` controls which attribution dimensions (customer, org, app, team, environment, model, provider, credential, policy version) are part of the cache key. Narrowing this (e.g. dropping `app` from the scope) lets identical prompts from different apps on the same customer share a cache entry. `customer`, `credential`, and `policy_version` can never be dropped - tenant isolation always holds. This is configured on the policy by an admin, not by anything a client sends per request.

## Cache invalidation is an admin action, not a per-call flag

The only client-invocable cache-affecting action is `POST /v1/llm/exact-cache/invalidate` (scoped by `app_id`, `policy_id`, or `model`), which requires the `ai:admin` key. It doesn't delete entries directly - it bumps a generation counter so old entries stop matching. This is a governance action for an admin to take deliberately, not something an inference call can trigger.

## Caching latency and propagation

To maximize performance, cache writes are processed in the background. Because of this brief propagation delay, rapid-fire repeats sent immediately after a cache miss may fall through to the provider before the cache entry is fully active. Give the gateway a moment to index the new response before testing subsequent repeats.

## Semantic cache has an extra approval gate

A policy with `semantic_cache_mode: "enforce"` and `semantic_cache_review_required: true` serves a semantic hit only for an approved `(app_id, route, model_family)` class (`POST /v1/llm/semantic-cache/class-approvals`). Until a class is approved, its would-be hits are recorded but not served. This is intentional - semantic matches are approximate, so enforcement can be opted into per class, not only as a blanket policy switch. Neither approval step is something a client request can trigger or bypass.
