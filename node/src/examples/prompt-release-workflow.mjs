/**
 * Prompt Engineering CI/CD: Automated Evaluation Gates & Production Promotion
 *
 * In production AI systems, editing a prompt directly in production risks silent regressions
 * across classification accuracy, safety compliance, or formatting.
 *
 * Cloptima provides an integrated prompt registry and automated quality gates:
 * 1. Prompt Versioning: Prompts are managed as immutable versions in a central registry.
 * 2. Golden Datasets: Real production traffic or curated test cases form benchmark datasets.
 * 3. Automated Eval Runs: Candidate prompt versions are evaluated against accuracy thresholds.
 * 4. Production Release Gates: Prompt versions cannot be activated in production without
 *    satisfying evaluation quality gates and release approvals.
 */
import { openaiClient } from '../lib/client.mjs';
import { provisionApp } from '../lib/access.mjs';
import { runSuffix } from '../lib/config.mjs';
import { graphql } from '../lib/gatewayAdmin.mjs';
import { MODELS } from '../lib/models.mjs';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const suffix = runSuffix();
  console.log('Connecting to Cloptima Gateway with Prompt Registry...');
  // Governance setup (needs CLOPTIMA_AI_ADMIN_KEY): platform admins normally create the policy,
  // key, and binding once in the Console, Terraform, or CI.
  const { virtualKey, appId } = await provisionApp({
    app: 'prompt-release-demo',
    policy: {
      name: 'prompt-release-policy',
      mode: 'enforce',
      budgetMode: 'hard_fast',
      allowedProviders: ['vertex_ai'],
      allowedModels: [MODELS.default],
      promptRetentionMode: 'full',
    },
  });

  // Application code: the official SDK, pointed at the gateway with a virtual key.
  const client = openaiClient(virtualKey);

  console.log('\nGenerating baseline traffic for dataset creation...');
  await client.chat.completions.create({
    model: MODELS.default,
    messages: [{ role: 'user', content: 'In one word (auth/billing/technical), classify: I forgot my password.' }],
  });
  await client.chat.completions.create({
    model: MODELS.default,
    messages: [{ role: 'user', content: 'In one word (auth/billing/technical), classify: I was charged twice for my subscription.' }],
  });
  console.log('Baseline classification requests logged. Waiting for audit log ingestion...');
  await sleep(3000);

  console.log('\nCreating golden dataset for prompt evaluation...');
  const { createLLMDataset: dataset } = await graphql(
    `mutation CreateDataset($input: LLMDatasetInput!) {
      createLLMDataset(input: $input) { id name recordCount }
    }`,
    {
      input: {
        name: `support-intent-benchmark-${suffix}`,
        description: 'Golden benchmark dataset for support ticket intent classifier',
        appId,
        isGolden: true,
      },
    },
  );
  console.log(`Golden dataset created: ID ${dataset.id} (${dataset.recordCount} records)`);

  const datasetInfo = await graphql(
    `query GetDataset($id: ID!) {
      llmDataset(id: $id, includeRecords: true) { id records }
    }`,
    { id: dataset.id },
  );

  const records = datasetInfo.llmDataset.records || [];
  records.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
  const [r1, r2] = records;

  if (r1 && r2) {
    await graphql(
      `mutation SetLabels($input: LLMDatasetLabelsInput!) {
        setLLMDatasetLabels(input: $input) { id }
      }`,
      {
        input: {
          datasetId: dataset.id,
          expectedOutputs: {
            [r1.id]: 'auth',
            [r2.id]: 'billing',
          },
        },
      },
    );
    console.log('Expected classification labels assigned to benchmark records.');
  }

  console.log('\nCreating production prompt template in Cloptima registry...');
  const { createLLMPromptTemplate: template } = await graphql(
    `mutation CreateTemplate($input: LLMPromptTemplateInput!) {
      createLLMPromptTemplate(input: $input) { id name environment }
    }`,
    {
      input: {
        name: `support-intent-classifier-${suffix}`,
        owner: 'cloptima-ai-gateway-examples',
        description: 'Production ticket intent classifier',
        appId,
        environment: 'production',
      },
    },
  );

  console.log('Drafting candidate prompt version (v1)...');
  const { createLLMPromptVersion: version } = await graphql(
    `mutation CreateVersion($templateId: ID!, $input: LLMPromptVersionInput!) {
      createLLMPromptVersion(templateId: $templateId, input: $input) { id status }
    }`,
    {
      templateId: template.id,
      input: {
        content: 'You are a ticket classifier. Respond with one word: auth, billing, or technical.',
        changeSummary: 'Initial production prompt candidate',
        activate: false,
      },
    },
  );
  console.log(`Drafted prompt version: ${version.id} (Status: ${version.status})`);

  // Step 1: Run failing evaluation
  console.log('\n[CI/CD Gate 1] Executing eval run with candidate outputs failing threshold (<80%)...');
  const { createLLMEvalRun: evalFail } = await graphql(
    `mutation CreateEvalRun($input: LLMEvalRunInput!) {
      createLLMEvalRun(input: $input) { id status passed }
    }`,
    {
      input: {
        datasetId: dataset.id,
        evalType: 'deterministic',
        targetKind: 'prompt_change',
        subjectRef: { recommendation_id: version.id },
        runNow: true,
        threshold: 0.8,
        config: {
          candidate_outputs: {
            ...(r1 ? { [r1.id]: 'auth' } : {}),
            ...(r2 ? { [r2.id]: 'technical' } : {}), // Wrong output for billing ticket
          },
        },
      },
    },
  );
  console.log(`Eval run completed: Passed = ${evalFail.passed} (Score below 80% threshold)`);

  const { createLLMReleaseApproval: releaseFail } = await graphql(
    `mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
      createLLMReleaseApproval(input: $input) { id state }
    }`,
    {
      input: {
        subjectKind: 'prompt_deployment',
        subjectId: version.id,
        evalRunId: evalFail.id,
        applyImmediately: true,
      },
    },
  );
  console.log(`Release approval status: ${releaseFail.state} (Gate rejected)`);

  console.log('Attempting production activation for failing candidate:');
  try {
    await graphql(
      `mutation Activate($templateId: ID!, $versionId: ID!) {
        activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
      }`,
      { templateId: template.id, versionId: version.id },
    );
    console.log('Warning: Activation succeeded unexpectedly.');
  } catch (err) {
    console.log(`Expected release gate block: ${err.message}`);
    console.log('Production safety: Unverified prompt blocked from reaching live users.');
  }

  // Step 2: Run passing evaluation
  console.log('\n[CI/CD Gate 2] Executing eval run with candidate outputs satisfying threshold (100% >= 80%)...');
  const { createLLMEvalRun: evalPass } = await graphql(
    `mutation CreateEvalRun($input: LLMEvalRunInput!) {
      createLLMEvalRun(input: $input) { id status passed }
    }`,
    {
      input: {
        datasetId: dataset.id,
        evalType: 'deterministic',
        targetKind: 'prompt_change',
        subjectRef: { recommendation_id: version.id },
        runNow: true,
        threshold: 0.8,
        config: {
          candidate_outputs: {
            ...(r1 ? { [r1.id]: 'auth' } : {}),
            ...(r2 ? { [r2.id]: 'billing' } : {}), // Correct output
          },
        },
      },
    },
  );
  console.log(`Eval run completed: Passed = ${evalPass.passed} (100% accuracy)`);

  const { createLLMReleaseApproval: releasePass } = await graphql(
    `mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
      createLLMReleaseApproval(input: $input) { id state }
    }`,
    {
      input: {
        subjectKind: 'prompt_deployment',
        subjectId: version.id,
        evalRunId: evalPass.id,
        applyImmediately: true,
      },
    },
  );
  console.log(`Release approval status: ${releasePass.state} (Gate passed)`);

  console.log('Promoting validated prompt version to production:');
  const { activateLLMPromptVersion: activated } = await graphql(
    `mutation Activate($templateId: ID!, $versionId: ID!) {
      activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
    }`,
    { templateId: template.id, versionId: version.id },
  );
  console.log(`Prompt version promoted: ID ${activated.id} (Status: ${activated.status})`);
  console.log('\nCI/CD Pipeline complete: Only validated, regression-tested prompts reach production.');
}

main().catch((err) => {
  console.error('prompt-release-workflow execution failed:', err.message);
  process.exitCode = 1;
});
