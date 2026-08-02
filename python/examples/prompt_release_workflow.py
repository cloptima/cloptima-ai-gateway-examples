"""Prompt registry / dataset / eval / release-gate workflow: create a prompt
template, draft a version, back an eval run with a dataset, and gate
promotion behind that eval plus a release approval.

An eval run only counts as release-gate evidence for a prompt version when
created with subjectRef: { recommendation_id: versionId } and targetKind:
'prompt_change'. For a production-environment template, activating a
version checks the release gate and returns a 409 if the release approval
hasn't been DECIDED yet - and deciding it is the same kind of human-review
step approval_workflow.py doesn't script either, so this example expects
and prints that 409 as the demonstrated behavior, not a failure. No live
gateway inference call here - this is a content/release-governance flow,
not a runtime-enforcement one.
Run standalone from python/:
    python -m examples.prompt_release_workflow
"""

import json

from lib import config
from lib.gateway_admin import graphql


def main():
    suffix = config.run_suffix()
    app_id = f"prompt-release-{suffix}"

    print("Creating a production-environment prompt template...")
    template_data = graphql(
        """mutation CreateTemplate($input: LLMPromptTemplateInput!) {
          createLLMPromptTemplate(input: $input) { id name environment }
        }""",
        {"input": {
            "name": f"prompt-release-workflow-{suffix}",
            "owner": "cloptima-ai-gateway-examples",
            "description": "Support-ticket acknowledgement prompt (example run)",
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
                "content": "Draft a one-sentence acknowledgement reply to this customer support ticket:\n\n{{ticket_text}}",
                "changeSummary": "Initial draft",
                "activate": False,
            },
        },
    )
    version = version_data["createLLMPromptVersion"]
    print(f"  version {version['id']} (status={version['status']})")

    print("Creating a dataset to back the eval run...")
    dataset_data = graphql(
        """mutation CreateDataset($input: LLMDatasetInput!) {
          createLLMDataset(input: $input) { id name recordCount }
        }""",
        {"input": {
            "name": f"prompt-release-workflow-dataset-{suffix}",
            "description": "Example dataset for prompt-release-workflow",
            "appId": app_id,
            "isGolden": False,
        }},
    )
    dataset = dataset_data["createLLMDataset"]
    print(f"  dataset {dataset['id']} (recordCount={dataset['recordCount']})")

    print("Running an eval against this version (subjectRef.recommendation_id must equal the version id)...")
    eval_run_data = graphql(
        """mutation CreateEvalRun($input: LLMEvalRunInput!) {
          createLLMEvalRun(input: $input) { id status passed }
        }""",
        {"input": {
            "datasetId": dataset["id"],
            "evalType": "deterministic",
            "targetKind": "prompt_change",
            "subjectRef": {"recommendation_id": version["id"]},
            "runNow": True,
        }},
    )
    eval_run = eval_run_data["createLLMEvalRun"]
    print(f"  eval run {eval_run['id']} (status={eval_run['status']}, passed={eval_run['passed']})")

    print("Requesting a release approval for the production promotion (subjectKind: prompt_deployment)...")
    release_approval_data = graphql(
        """mutation CreateReleaseApproval($input: LLMReleaseApprovalInput!) {
          createLLMReleaseApproval(input: $input) { id state subjectKind subjectId }
        }""",
        {"input": {
            "subjectKind": "prompt_deployment",
            "subjectId": version["id"],
            "evalRunId": eval_run["id"],
        }},
    )
    release_approval = release_approval_data["createLLMReleaseApproval"]
    print(f"  release approval {release_approval['id']} (state={release_approval['state']})")

    print("\nAttempting to activate the version (expected to be blocked - the release approval above is pending, not decided)...")
    try:
        activated_data = graphql(
            """mutation Activate($templateId: ID!, $versionId: ID!) {
              activateLLMPromptVersion(templateId: $templateId, versionId: $versionId) { id status }
            }""",
            {"templateId": template["id"], "versionId": version["id"]},
        )
        print(f"  activated: {json.dumps(activated_data['activateLLMPromptVersion'])} (unexpected unless the release approval was already decided on a prior run)")
    except RuntimeError as err:
        print(f"  blocked: {err}")
        print(
            "  Expected: HTTP 409 - production activation is gated on the release approval being DECIDED, not just "
            "requested. Deciding it (decideLLMReleaseApproval) is a second-identity review step in the console, not "
            "something this script does on the requester's own behalf. Re-run activation after approving in the console."
        )

    print(f"\nEvidence: Audit tab ({config.CONSOLE['audit']}) shows the pending release approval; Policies tab ({config.CONSOLE['policies']}) area's prompt registry view remains in draft / pending-release status until approved.")


if __name__ == "__main__":
    main()
