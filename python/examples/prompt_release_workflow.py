"""Prompt registry / dataset / eval / release-gate workflow: create a prompt
template, draft a version, back an eval run with a dataset, and gate
promotion behind that eval plus a release approval.

To demonstrate the evaluation engine's automated validation capability,
this script first sends baseline requests through the gateway to generate
audit logs, builds a golden dataset from those logs, and labels them with
expected outputs. It then runs deterministic evaluation runs: first a failing
run to show quality gates blocking production activation, and then a passing
run that allows activation to succeed.

For a production-environment template, activating a version checks the
release gate and returns a 409 if the release approval hasn't been
DECIDED yet. At the end, the same release approval is requested again with
applyImmediately: true. Since this key already qualifies to decide it
itself and the evaluation is passing, it's approved right away and activation succeeds.
Run standalone from python/:
    python -m examples.prompt_release_workflow
"""

import json
import time
import requests

from lib import config
from lib.confirm import confirm_equals
from lib.gateway_admin import graphql, create_policy, create_virtual_key, create_binding


def main():
    suffix = config.run_suffix()
    app_id = f"prompt-release-{suffix}"

    print("Creating baseline policy and virtual key...")
    policy = create_policy({
        "name": f"prompt-release-policy-{suffix}",
        "mode": "enforce",
        "budgetMode": "hard_fast",
        "allowedProviders": ["vertex_ai"],
        "allowedModels": ["vertex_ai/gemini-2.5-flash"],
        "promptRetentionMode": "full"
    })

    key = create_virtual_key({
        "name": f"vk-prompt-release-{suffix}",
        "teamId": "Platform AI",
        "appId": app_id,
        "environment": "production"
    })
    access_token = key["accessToken"]

    create_binding({
        "policyId": policy["id"],
        "teamId": "Platform AI",
        "appId": app_id,
        "environment": "production",
        "priority": 10,
        "acknowledgeOverlap": True
    })
    print("  Policy bound, waiting for binding propagation...")
    time.sleep(3)

    def call_chat(prompt: str, label: str):
        response = requests.post(
            f"{config.BASE_URL}/v1/ai/chat/completions",
            headers={
                "content-type": "application/json",
                "user-agent": config.USER_AGENT,
                "authorization": f"Bearer {access_token}",
            },
            json={"model": "vertex_ai/gemini-2.5-flash", "messages": [{"role": "user", "content": prompt}]},
            timeout=30,
        )
        print(f"  [{'allowed' if response.status_code == 200 else 'blocked'}] {label} (http {response.status_code})")

    print("Sending live chat calls to generate audit logs...")
    call_chat(
        "In one word (auth/billing/technical), classify this support ticket: I forgot my password, how do I reset it?",
        "ticket-1-auth"
    )
    call_chat(
        "In one word (auth/billing/technical), classify this support ticket: I was charged twice for my premium account.",
        "ticket-2-billing"
    )

    print("  Sent requests, waiting for logs to flush...")
    time.sleep(3)

    print("Creating a golden dataset filtering by App ID...")
    dataset_data = graphql(
        """mutation CreateDataset($input: LLMDatasetInput!) {
          createLLMDataset(input: $input) { id name recordCount }
        }""",
        {"input": {
            "name": f"prompt-release-workflow-dataset-{suffix}",
            "description": "Example dataset for prompt-release-workflow",
            "appId": app_id,
            "isGolden": True,
        }},
    )
    dataset = dataset_data["createLLMDataset"]
    print(f"  dataset {dataset['id']} (recordCount={dataset['recordCount']})")

    if dataset["recordCount"] < 2:
        raise RuntimeError(f"Error: Golden dataset contains {dataset['recordCount']} records, expected at least 2!")

    print("Retrieving dataset records to get expected output...")
    dataset_info = graphql(
        """query GetDataset($id: ID!) {
          llmDataset(id: $id, includeRecords: true) {
            id
            records
          }
        }""",
        {"id": dataset["id"]},
    )
    records = dataset_info["llmDataset"]["records"]
    # Sort records by created_at ascending to align them with prompt execution order
    records.sort(key=lambda r: r["created_at"])
    r1_id = records[0]["id"]
    r2_id = records[1]["id"]
    print(f"  record 1 ID: {r1_id} (Expected: auth)")
    print(f"  record 2 ID: {r2_id} (Expected: billing)")

    print("Setting expected output labels on the records...")
    graphql(
        """mutation SetLabels($input: LLMDatasetLabelsInput!) {
          setLLMDatasetLabels(input: $input) { id }
        }""",
        {
            "input": {
                "datasetId": dataset["id"],
                "expectedOutputs": {
                    r1_id: "auth",
                    r2_id: "billing",
                },
            }
        },
    )

    print("Creating a production-environment prompt template...")
    template_data = graphql(
        """mutation CreateTemplate($input: LLMPromptTemplateInput!) {
          createLLMPromptTemplate(input: $input) { id name environment }
        }""",
        {"input": {
            "name": f"prompt-release-workflow-{suffix}",
            "owner": "cloptima-ai-gateway-examples",
            "description": "Intent Classifier Prompt",
            "appId": app_id, "environment": "production",
        }},
    )
    template = template_data["createLLMPromptTemplate"]
    print(f"  template {template['id']} (environment={template['environment']})")

    print("Drafting a version (activate: false - direct activate-on-create is never allowed for production templates)...")
    version_data = graphql(
        """mutation CreateVersion($templateId: ID!, $input: LLMPromptVersionInput!) {
          createLLMPromptVersion(templateId: $templateId, input: $input) { id status }
        }""",
        {
            "templateId": template["id"],
            "input": {
                "content": "Intent Classifier template v1",
                "changeSummary": "Initial version",
                "activate": False,
            },
        },
    )
    version = version_data["createLLMPromptVersion"]
    print(f"  version {version['id']} (status={version['status']})")

    print("Running deterministic evaluation run with failing candidate output config...")
    # We pass a wrong output for record 2 ('technical' instead of 'billing') to fail the 80% threshold
    eval_run_fail = graphql(
        """mutation CreateEvalRun($input: LLMEvalRunInput!) {
          createLLMEvalRun(input: $input) { id status passed }
        }""",
        {"input": {
            "datasetId": dataset["id"],
            "evalType": "deterministic",
            "targetKind": "prompt_change",
            "subjectRef": {"recommendation_id": version["id"]},
            "runNow": True,
            "threshold": 0.8,
            "config": {
                "candidate_outputs": {
                    r1_id: "auth",
                    r2_id: "technical",
                }
            }
        }},
    )["createLLMEvalRun"]
    print(f"  failing eval run {eval_run_fail['id']} (status={eval_run_fail['status']}, passed={eval_run_fail['passed']})")

    print("Requesting release approval with applyImmediately: true for the failing eval run...")
    release_approval_fail = graphql(
        """mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
          createLLMReleaseApproval(input: $input) { id state }
        }""",
        {"input": {
            "subjectKind": "prompt_deployment",
            "subjectId": version["id"],
            "evalRunId": eval_run_fail["id"],
            "applyImmediately": True,
        }},
    )["createLLMReleaseApproval"]
    print(f"  release approval {release_approval_fail['id']} (state={release_approval_fail['state']})")

    print("\nAttempting to activate the version (expected to be blocked - the evaluation run failed the quality gate)...")
    try:
        activated = graphql(
            """mutation Activate($templateId: ID!, $versionId: ID!) {
              activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
            }""",
            {"templateId": template["id"], "versionId": version["id"]},
        )
        raise RuntimeError(f"quality gate did not hold: activation succeeded while the release approval was still pending ({json.dumps(activated)})")
    except RuntimeError as err:
        if "quality gate did not hold" in str(err):
            raise
        print(f"  blocked: {err}")
        print(
            "  Confirmed: production activation is blocked because the release approval remained pending\n"
            "  (gate failed due to the latest evaluation run scoring 50% vs required 80% threshold)."
        )

    print("\nRunning deterministic evaluation run with passing candidate output config...")
    # We pass the correct output ('billing') to satisfy the 80% threshold
    eval_run_pass = graphql(
        """mutation CreateEvalRun($input: LLMEvalRunInput!) {
          createLLMEvalRun(input: $input) { id status passed }
        }""",
        {"input": {
            "datasetId": dataset["id"],
            "evalType": "deterministic",
            "targetKind": "prompt_change",
            "subjectRef": {"recommendation_id": version["id"]},
            "runNow": True,
            "threshold": 0.8,
            "config": {
                "candidate_outputs": {
                    r1_id: "auth",
                    r2_id: "billing",
                }
            }
        }},
    )["createLLMEvalRun"]
    print(f"  passing eval run {eval_run_pass['id']} (status={eval_run_pass['status']}, passed={eval_run_pass['passed']})")

    print("Requesting release approval with applyImmediately: true for the passing eval run...")
    release_approval_pass = graphql(
        """mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
          createLLMReleaseApproval(input: $input) { id state }
        }""",
        {"input": {
            "subjectKind": "prompt_deployment",
            "subjectId": version["id"],
            "evalRunId": eval_run_pass["id"],
            "applyImmediately": True,
        }},
    )["createLLMReleaseApproval"]
    print(f"  release approval {release_approval_pass['id']} (state={release_approval_pass['state']})")

    print("\nRetrying activation now that the passing release approval is decided...")
    activated_pass = graphql(
        """mutation Activate($templateId: ID!, $versionId: ID!) {
          activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
        }""",
        {"templateId": template["id"], "versionId": version["id"]},
    )["activateLLMPromptVersion"]
    print(f"  activated: {json.dumps(activated_pass)}")
    confirm_equals(activated_pass.get("status") if activated_pass else None, "active", "passing evaluation run with applyImmediately: true should activate")
    print(
        "Confirmed: this activation succeeds - applyImmediately: true auto-approved the gate because the latest\n"
        "evaluation run met the 80% quality threshold."
    )
    print(f"\nEvidence: Audit tab ({config.CONSOLE['audit']}) shows both release approvals - the first still pending (failed gate), the second already decided; Policies tab ({config.CONSOLE['policies']}) shows this version now active.")


if __name__ == "__main__":
    main()
