# Console guide

Every example script prints an `Evidence:` line telling you which console tab proves what it just did. This doc is the consolidated version of that - useful if you want the full picture up front instead of tab-hopping one script at a time.

## Logging in

The console is a normal email/password login at your product console URL (e.g. `https://app.cloptima.ai`) - no SSO or special client needed. Use the login you were given. Once in, the main Dashboard overview lives on the root path `/`, while other sub-tabs live under `/llm/*`.

## Tab map

| Tab | Path | What it shows | Populated by |
| --- | --- | --- | --- |
| Dashboard | `/` | Org-wide FinOps rollups, including realized cache savings and blended effective cost (retail vs. contracted). | `exact-semantic-cache`, `contract-pricing` |
| Explorer | `/llm/spend` | Per-request attributed spend, usage, latency, and cached-token counts. Filterable by app/team/model. | `quickstart-openai`, `quickstart-anthropic`, `multi-model`, `budget-limit`, `exact-semantic-cache`, `byok` |
| Economics | `/llm/unit-economics` | Cost-per-unit, margin, and net-ROI, computed from real submitted traffic - a cost-center agent (ROI vs. a pre-LLM baseline) next to a profit-center agent (real booked revenue). | `unit-economics-roi` |
| Recommendations | `/llm/recommendations` | Cost-optimization suggestions (model right-sizing, caching, guardrail tuning) computed from real usage history over time. Nothing here immediately after a single script run - it needs accumulated traffic. | Builds up from all traffic over time, not any one script |
| Policies | `/llm/policies` | Every policy config created so far: limits, guardrails, cache modes. | Every example that calls `createLLMGatewayPolicy` |
| Credentials | `/llm/credentials` | Virtual keys and BYOK provider credentials. | Every example (virtual keys); `byok` (provider credential) |
| Audit | `/llm/audit` | Blocked-request records - policy, provider, model, token, guardrail, and agentic-limit blocks, each with the reason and violation detail. | `rate-limit`, `token-limit`, `budget-limit`, `agentic-runaway`, `pii-guardrail`, `provider-deny`, `metadata-deny` |

## A five-minute walk, if you'd rather click than script

1. Run `quickstart-openai` (or any script) once, then open **Explorer** and find that request by app name - confirms attribution and spend are real, not simulated.
2. Open **Audit** after running any of the blocking examples (`rate-limit`, `pii-guardrail`, etc.) - each block record names the exact policy and reason that fired.
3. Open **Policies** to see the config each script created - nothing here was pre-provisioned; it's all created live by the `ai:admin` key.
4. Open **Economics** after `unit-economics-roi` - one app shows ROI against a pre-LLM baseline, the other shows a positive margin from real booked revenue, both computed from real submitted traffic, not hardcoded.
5. Open **Dashboard** after `contract-pricing` - the Blended Effective Cost card and Contract Pricing panel show retail vs. contracted cost for a real negotiated rate, not a hardcoded discount.

## Notes

- There's no separate "sandbox" UI - this is the same console every paying customer uses. What you're seeing is real product, not a demo shell.
- Filtering by app name is the fastest way to isolate one script's traffic from another's, since every example uses a unique app ID per run.
