/**
 * Customer Support Assistant with Personal Data (PII) Protection
 *
 * Demonstrates how an application calls models through Cloptima with a guardrail
 * profile that protects personal data, and how the application handles a guardrail block.
 *
 * Pattern:
 * 1. Governance setup: a guardrail profile that redacts US personal data (the
 *    `us_personal_data` template) and blocks employee IDs (a custom `employee_id` rule).
 * 2. Case 1: A message with an email address and a phone number is answered. The model
 *    provider sees placeholders such as [EMAIL_ADDRESS_7Q2M4K9XAB3C] instead of the values,
 *    and the gateway restores the values in the response, so the application gets its own
 *    data back.
 * 3. Case 2: A message with an employee ID is refused before it reaches the model (HTTP 403).
 *    The application reads the block reason and returns a friendly message.
 *
 * Prerequisite: custom rules and every template except `secrets` need the
 * `llm_guardrail_enterprise` entitlement.
 *
 * Run standalone:
 *   node src/examples/pii-guardrail.mjs
 */
import { openaiClient } from '../lib/client.mjs';
import { getAccess } from '../lib/access.mjs';
import { MODELS } from '../lib/models.mjs';
import { CONSOLE } from '../lib/config.mjs';

const CUSTOMER_EMAIL = 'jane.doe@example.com';
const CUSTOMER_PHONE = '415-555-0142';

async function main() {
  console.log('=== Customer Support Assistant: PII & Guardrails ===\n');

  // Governance setup: a guardrail profile attached to the policy this application runs under.
  // Platform admins normally create these once in the Console, Terraform, or CI. Skipped when
  // CLOPTIMA_VIRTUAL_KEY points at a key whose policy already matches.
  const access = await getAccess({
    app: 'support-bot-demo',
    guardrailProfile: {
      name: 'support-guardrail-profile',
      description: 'Customer support: redact US personal data, block employee IDs',
      definition: {
        protect: [
          // Latest version of the template; add `version` to pin one.
          { template: 'us_personal_data', action: 'redact' },
          // Matches a value such as "Employee ID: E482913", in any letter case.
          { rule: 'employee_id', match: { label: '(?i:employee id)', value: 'E\\d{6}' }, action: 'block' },
        ],
      },
    },
    policy: {
      name: 'support-guardrail-policy',
      mode: 'enforce',
      budget_mode: 'hard',
      fail_mode: 'fail_closed',
      allowed_providers: ['vertex_ai'],
      allowed_models: [MODELS.default],
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(access.virtualKey);

  // Case 1: personal data is redacted for the provider and restored for the application.
  console.log('--- Case 1: Query Containing an Email Address and Phone Number ---');
  const contactPrompt = `I can't sign in. My account email is ${CUSTOMER_EMAIL} and my phone is ${CUSTOMER_PHONE}. Repeat my contact details back to me, then tell me the next step.`;
  console.log(`User: "${contactPrompt}"`);

  try {
    const response = await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: contactPrompt }],
    });
    const reply = response.choices[0].message.content.trim();
    console.log(`Assistant: ${reply}\n`);
    console.log('The model provider received placeholders such as [EMAIL_ADDRESS_7Q2M4K9XAB3C] instead of');
    console.log('the email address and phone number. The gateway restored the values in the response.');
    if (reply.includes(CUSTOMER_EMAIL) || reply.includes(CUSTOMER_PHONE)) {
      console.log('✓ The answer shows the customer\'s own contact details.');
    }
    console.log();
  } catch (err) {
    console.error('Unexpected error:', err.message);
  }

  // Case 2: a block rule refuses the request before it reaches the model.
  console.log('--- Case 2: Query Containing an Employee ID ---');
  const employeePrompt = 'Please apply my staff discount to order 1042. My Employee ID: E482913.';
  console.log(`User: "${employeePrompt}"`);

  try {
    await client.chat.completions.create({
      model: MODELS.default,
      messages: [{ role: 'user', content: employeePrompt }],
    });
    console.log('Assistant: (Processed unexpectedly)\n');
  } catch (err) {
    if (err.status === 403) {
      // The gateway's block body: { error: "<message>", reason: "gateway_guardrail_blocked", violations: [...] }.
      // A custom rule's violation is `custom_<rule id>`, here `custom_employee_id`.
      const errorBody = err.error || {};
      console.log('\n[Gateway Guardrail Block: HTTP 403]');
      console.log(`  Reason: ${errorBody.reason || 'unknown'}`);
      console.log(`  Message: ${errorBody.message || err.message}`);
      if (errorBody.violations?.length) {
        console.log(`  Violations: ${errorBody.violations.join(', ')}`);
      }

      // Application handles the error gracefully for the end user:
      console.log('\nApplication Fallback Response to End User:');
      console.log('  "Notice: For your security, please do not include employee IDs in support requests. Please submit your request without internal identifiers."\n');
    } else {
      throw err;
    }
  }

  console.log(`Evidence in Cloptima Console:`);
  console.log(`  - Guardrail profiles: ${CONSOLE.guardrails}`);
  console.log(`  - Audit trail: ${CONSOLE.audit}`);
}

main().catch((err) => {
  console.error('Example failed:', err.message);
  process.exitCode = 1;
});
