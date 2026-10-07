/**
 * Customer Support Assistant with Personal Data (PII) Protection
 *
 * Demonstrates how an application calls models through Cloptima with an active
 * guardrail profile, and how the application handles guardrail blocks gracefully.
 *
 * Pattern:
 * 1. Initialize official OpenAI SDK with Cloptima gateway URL & virtual key.
 * 2. Send normal user support inquiries (served normally).
 * 3. Send inquiry containing sensitive personal data (e.g. US SSN format).
 * 4. Catch the 403 governance block, inspect violations, and return friendly
 *    user-facing feedback instead of failing or leaking sensitive data.
 *
 * Run standalone:
 *   node src/examples/pii-guardrail.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

async function main() {
  console.log('=== Customer Support Assistant: PII & Guardrails ===\n');

  // Governance setup: a guardrail profile that blocks credentials and US SSN formats on input,
  // attached to the policy this application runs under. Platform admins normally create these
  // once in the Console, Terraform, or CI. Skipped when CLOPTIMA_VIRTUAL_KEY points at a key
  // whose policy already matches.
  const access = await getAccess({
    app: 'support-bot-demo',
    guardrailProfile: {
      name: 'support-guardrail-profile',
      description: 'Customer support safety profile: blocks credentials and US SSN personal data formats',
      definition: {
        input: {
          action: 'block',
          detectors: { secret: {} },
          custom_rules: [{ id: 'us_ssn', match: { regex: '\\b\\d{3}-\\d{2}-\\d{4}\\b' } }],
        },
        output: { action: 'observe', detectors: { secret: {} } },
      },
    },
    policy: {
      name: 'support-guardrail-policy',
      mode: 'enforce',
      budgetMode: 'hard',
      failMode: 'fail_closed',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  // 2. Normal customer query: Allowed and processed normally
  console.log('--- Case 1: Standard Customer Query ---');
  const cleanPrompt = 'I need help resetting my account password for user@example.com.';
  console.log(`User: "${cleanPrompt}"`);

  try {
    const response = await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: cleanPrompt }],
    });
    console.log(`Assistant: ${response.choices[0].message.content.trim()}\n`);
  } catch (err) {
    console.error('Unexpected error:', err.message);
  }

  // 3. Sensitive customer query containing SSN format: Blocked by Guardrail Profile
  console.log('--- Case 2: Query Containing Sensitive Personal Data ---');
  const sensitivePrompt = 'My claim reference number is associated with SSN 123-45-6789. Can you update my record?';
  console.log(`User: "${sensitivePrompt}"`);

  try {
    await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: sensitivePrompt }],
    });
    console.log('Assistant: (Processed unexpectedly)\n');
  } catch (err) {
    if (err.status === 403) {
      // Cloptima guardrail or policy violation
      const errorBody = err.error || {};
      const reason = errorBody.reason || err.message;
      const violations = errorBody.violations || [];

      console.log('\n[Gateway Guardrail Block: HTTP 403]');
      console.log(`  Reason: ${reason}`);
      if (violations.length) {
        console.log(`  Violations detected: ${violations.join(', ')}`);
      }

      // Application handles the error gracefully for the end user:
      console.log('\nApplication Fallback Response to End User:');
      console.log('  "Notice: For your security, please do not include Social Security numbers or other sensitive identifiers in support requests. Please submit your request without personal identifiers."\n');
    } else {
      throw err;
    }
  }

  console.log(`Evidence in Cloptima Console:`);
  console.log(`  - Audit trail: ${CONSOLE.audit}`);
  console.log(`  - Policies: ${CONSOLE.policies}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
