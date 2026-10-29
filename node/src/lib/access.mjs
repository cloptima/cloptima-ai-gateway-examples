import { config, runSuffix } from './config.mjs';
import { createPolicy, createGuardrailProfile, createVirtualKey, createBinding } from './gatewayAdmin.mjs';

const TEAM = 'AI Engineering';
const ENVIRONMENT = 'development';

// Governance setup: creates the policy (and optional guardrail profile), a
// virtual key, and the binding that attaches the policy to that key's
// team/app/environment. Platform teams normally do this once in the Console,
// Terraform, or CI. Each example passes its policy definition inline, with the
// API's field names, so the configuration being demonstrated is visible next
// to the application code. Requires CLOPTIMA_AI_ADMIN_KEY.
export async function provisionApp({ app, policy, guardrailProfile, team = TEAM, environment = ENVIRONMENT }) {
  const suffix = runSuffix();
  const appId = `${app}-${suffix}`;

  const profile = guardrailProfile
    ? await createGuardrailProfile({ ...guardrailProfile, name: `${guardrailProfile.name}-${suffix}` })
    : undefined;
  const createdPolicy = await createPolicy({
    ...policy,
    name: `${policy.name}-${suffix}`,
    ...(profile && { guardrail_profile_id: profile.id }),
  });
  const key = await createVirtualKey({ name: `vk-${appId}`, team_id: team, app_id: appId, environment });
  await createBinding({
    policy_id: createdPolicy.id,
    team_id: team,
    app_id: appId,
    environment,
    priority: 10,
    acknowledge_overlap: true,
  });

  return { virtualKey: key.access_token, appId, teamId: team, environment, policy: createdPolicy, profile, suffix };
}

// Returns the virtual key the application code should use.
// - CLOPTIMA_VIRTUAL_KEY set: use it as-is. The key must already be bound to a
//   policy equivalent to the one in the example's governance setup.
// - Otherwise: run the governance setup with CLOPTIMA_AI_ADMIN_KEY.
export async function getAccess(setup) {
  if (config.virtualKey) {
    console.log('Using CLOPTIMA_VIRTUAL_KEY. The key should be bound to a policy like the governance setup in this file.\n');
    return { virtualKey: config.virtualKey, provisioned: false };
  }
  if (!config.aiAdminKey) {
    throw new Error(
      'Set CLOPTIMA_VIRTUAL_KEY to use an existing key, or CLOPTIMA_AI_ADMIN_KEY to let this example create its own policy and key (see .env.example).',
    );
  }
  return { ...(await provisionApp(setup)), provisioned: true };
}
