# Cache and policy behavior

## There is no client-side cache toggle

Exact-cache and semantic-cache behavior is entirely server-side and policy-driven. A request cannot ask for caching to be enabled, disabled, or bypassed - there is no header or body field for it. What determines caching:

- Whether the policy bound to your virtual key has `exactCacheEnabled` / `semanticCacheEnabled` turned on, and in which mode (`off`, `observe`, `suggest`, `enforce`-style).
- Route, model, and content-class allow-lists on the policy.
- Payload size, streaming, and sensitive-data-detection rules on the policy.
- `promptRetentionMode: "full"` when exact-cache responses should actually be replayed. Without it, the gateway stores metadata-only would-hit evidence and still calls the provider.

If you send the exact same prompt repeatedly (as the `exact-semantic-cache` example does) and the bound policy has exact-cache enabled, you should see the effect in the console (lower latency, cache-hit evidence in Explorer/Audit) even though nothing in the example code asks for it explicitly.

## Attribution headers can affect cache scope, indirectly

A policy-level setting called `exactCacheKeyScope` controls which attribution dimensions (customer, org, app, team, environment, model, provider, credential, policy version) are part of the cache key. Narrowing this (e.g. dropping `app` from the scope) lets identical prompts from different apps on the same customer share a cache entry. `customer`, `credential`, and `policy_version` can never be dropped - tenant isolation always holds. This is configured on the policy by an admin, not by anything a client sends per request.

## Cache invalidation is an admin action, not a per-call flag

The only client-invocable cache-affecting action is the `invalidateLLMExactCache` GraphQL mutation (scoped by app/policy/model), which requires the `ai:admin` key. It doesn't delete entries directly - it bumps a generation counter so old entries stop matching. This is a governance action for an admin to take deliberately, not something an inference call can trigger.

## Semantic cache has an extra approval gate

Even with `semanticCacheMode: "enforce"` set on a policy, semantic-cache enforcement additionally requires a per-`(app, content_class, model_family)` approval before it actually enforces (it downgrades to `suggest` until approved). This is intentional - semantic matches are approximate, so enforcement is opt-in per content type, not a blanket policy switch. Neither approval step is something a client request can trigger or bypass.
