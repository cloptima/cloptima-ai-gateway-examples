"""Prompt Engineering CI/CD: Automated Evaluation Gates & Production Promotion

In production AI systems, editing a prompt directly in production risks silent regressions
across classification accuracy, safety compliance, or formatting.

Cloptima provides an integrated prompt registry and automated quality gates:
1. Prompt Versioning: Prompts are managed as immutable versions in a central registry.
2. Golden Datasets: Real production traffic or curated test cases form benchmark datasets.
3. Automated Eval Runs: Candidate prompt versions are evaluated against accuracy thresholds.
4. Production Release Gates: Prompt versions cannot be activated in production without
   satisfying evaluation quality gates and release approvals.

Run standalone:
  python -m examples.prompt_release_workflow
"""
import time

from lib import config, gateway_admin
from lib.access import provision_app
from lib.client import openai_client
from lib.models import MODELS


def main() -> None:
    suffix = config.run_suffix()
    print("Connecting to Cloptima Gateway with Prompt Registry...")
    setup = provision_app(
        app="prompt-release-demo",
        policy={
            "name": "prompt-release-policy",
            "mode": "enforce",
            "budgetMode": "hard_fast",
            "allowedProviders": ["vertex_ai"],
            "allowedModels": [MODELS["default"]],
            "promptRetentionMode": "full",
        },
    )
    app_id = setup["app_id"]
    client = openai_client(setup["virtual_key"])

    print("\nGenerating baseline traffic for dataset creation...")
    client.chat.completions.create(
        model=MODELS["default"],
        messages=[{"role": "user", "content": "In one word (auth/billing/technical), classify: I forgot my password."}],
    )
    client.chat.completions.create(
        model=MODELS["default"],
        messages=[{"role": "user", "content": "In one word (auth/billing/technical), classify: I was charged twice for my subscription."}],
    )
    print("Baseline classification requests logged. Waiting for audit log ingestion...")
    time.sleep(3.0)

    print("\nCreating golden dataset for prompt evaluation...")
    data = gateway_admin.graphql(
        """mutation CreateDataset($input: LLMDatasetInput!) {
          createLLMDataset(input: $input) { id name recordCount }
        }""",
        {
            "input": {
                "name": f"support-intent-benchmark-{suffix}",
                "description": "Golden benchmark dataset for support ticket intent classifier",
                "appId": app_id,
                "isGolden": True,
            }
        },
    )
    dataset = data["createLLMDataset"]
    print(f"Golden dataset created: ID {dataset['id']} ({dataset['recordCount']} records)")

    dataset_info = gateway_admin.graphql(
        """query GetDataset($id: ID!) {
          llmDataset(id: $id, includeRecords: true) { id records }
        }""",
        {"id": dataset["id"]},
    )
    records = (dataset_info.get("llmDataset") or {}).get("records") or []
    records.sort(key=lambda r: r.get("created_at", ""))
    r1 = records[0] if len(records) > 0 else None
    r2 = records[1] if len(records) > 1 else None

    if r1 and r2:
        gateway_admin.graphql(
            """mutation SetLabels($input: LLMDatasetLabelsInput!) {
              setLLMDatasetLabels(input: $input) { id }
            }""",
            {
                "input": {
                    "datasetId": dataset["id"],
                    "expectedOutputs": {
                        r1["id"]: "auth",
                        r2["id"]: "billing",
                    },
                }
            },
        )
        print("Expected classification labels assigned to benchmark records.")

    print("\nCreating production prompt template in Cloptima registry...")
    tmpl_data = gateway_admin.graphql(
        """mutation CreateTemplate($input: LLMPromptTemplateInput!) {
          createLLMPromptTemplate(input: $input) { id name environment }
        }""",
        {
            "input": {
                "name": f"support-intent-classifier-{suffix}",
                "owner": "cloptima-ai-gateway-examples",
                "description": "Production ticket intent classifier",
                "appId": app_id,
                "environment": "production",
            }
        },
    )
    template = tmpl_data["createLLMPromptTemplate"]

    print("Drafting candidate prompt version (v1)...")
    ver_data = gateway_admin.graphql(
        """mutation CreateVersion($templateId: ID!, $input: LLMPromptVersionInput!) {
          createLLMPromptVersion(templateId: $templateId, input: $input) { id status }
        }""",
        {
            "templateId": template["id"],
            "input": {
                "content": "You are a ticket classifier. Respond with one word: auth, billing, or technical.",
                "changeSummary": "Initial production prompt candidate",
                "activate": False,
            },
        },
    )
    version = ver_data["createLLMPromptVersion"]
    print(f"Drafted prompt version: {version['id']} (Status: {version['status']})")

    # Step 1: Run failing evaluation
    print("\n[CI/CD Gate 1] Executing eval run with candidate outputs failing threshold (<80%)...")
    eval_fail_data = gateway_admin.graphql(
        """mutation CreateEvalRun($input: LLMEvalRunInput!) {
          createLLMEvalRun(input: $input) { id status passed }
        }""",
        {
            "input": {
                "datasetId": dataset["id"],
                "evalType": "deterministic",
                "targetKind": "prompt_change",
                "subjectRef": {"recommendation_id": version["id"]},
                "runNow": True,
                "threshold": 0.8,
                "config": {
                    "candidate_outputs": {
                        **({r1["id"]: "auth"} if r1 else {}),
                        **({r2["id"]: "technical"} if r2 else {}),  # Wrong output for billing ticket
                    }
                },
            }
        },
    )
    eval_fail = eval_fail_data["createLLMEvalRun"]
    print(f"Eval run completed: Passed = {eval_fail['passed']} (Score below 80% threshold)")

    rel_fail_data = gateway_admin.graphql(
        """mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
          createLLMReleaseApproval(input: $input) { id state }
        }""",
        {
            "input": {
                "subjectKind": "prompt_deployment",
                "subjectId": version["id"],
                "evalRunId": eval_fail["id"],
                "applyImmediately": True,
            }
        },
    )
    release_fail = rel_fail_data["createLLMReleaseApproval"]
    print(f"Release approval status: {release_fail['state']} (Gate rejected)")

    print("Attempting production activation for failing candidate:")
    try:
        gateway_admin.graphql(
            """mutation Activate($templateId: ID!, $versionId: ID!) {
              activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
            }""",
            {"templateId": template["id"], "versionId": version["id"]},
        )
        print("Warning: Activation succeeded unexpectedly.")
    except Exception as err:
        print(f"Expected release gate block: {err}")
        print("Production safety: Unverified prompt blocked from reaching live users.")

    # Step 2: Run passing evaluation
    print("\n[CI/CD Gate 2] Executing eval run with candidate outputs satisfying threshold (100% >= 80%)...")
    eval_pass_data = gateway_admin.graphql(
        """mutation CreateEvalRun($input: LLMEvalRunInput!) {
          createLLMEvalRun(input: $input) { id status passed }
        }""",
        {
            "input": {
                "datasetId": dataset["id"],
                "evalType": "deterministic",
                "targetKind": "prompt_change",
                "subjectRef": {"recommendation_id": version["id"]},
                "runNow": True,
                "threshold": 0.8,
                "config": {
                    "candidate_outputs": {
                        **({r1["id"]: "auth"} if r1 else {}),
                        **({r2["id"]: "billing"} if r2 else {}),  # Correct output
                    }
                },
            }
        },
    )
    eval_pass = eval_pass_data["createLLMEvalRun"]
    print(f"Eval run completed: Passed = {eval_pass['passed']} (100% accuracy)")

    rel_pass_data = gateway_admin.graphql(
        """mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
          createLLMReleaseApproval(input: $input) { id state }
        }""",
        {
            "input": {
                "subjectKind": "prompt_deployment",
                "subjectId": version["id"],
                "evalRunId": eval_pass["id"],
                "applyImmediately": True,
            }
        },
    )
    release_pass = rel_pass_data["createLLMReleaseApproval"]
    print(f"Release approval status: {release_pass['state']} (Gate passed)")

    print("Promoting validated prompt version to production:")
    act_data = gateway_admin.graphql(
        """mutation Activate($templateId: ID!, $versionId: ID!) {
          activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
        }""",
        {"templateId": template["id"], "versionId": version["id"]},
    )
    activated = act_data["activateLLMPromptVersion"]
    print(f"Prompt version promoted: ID {activated['id']} (Status: {activated['status']})")
    print("\nCI/CD Pipeline complete: Only validated, regression-tested prompts reach production.")


if __name__ == "__main__":
    main()
