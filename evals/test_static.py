"""
Static structural checks — no API calls, runs in milliseconds.

These tests verify that the task definition files are internally consistent:
- All referenced task files exist
- The plan routing table covers all required decision branches
- Input/output fields chain correctly between tasks
- Every task defines an output report schema
- Every task specifies the correct model in its frontmatter
"""
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent

VALID_MODELS = {
    "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5",
    "anthropic/claude-opus-4-7", "anthropic/claude-sonnet-4-6", "anthropic/claude-haiku-4.5",
}

TASK_FILES = [
    *[p.relative_to(REPO_ROOT) for p in sorted(REPO_ROOT.glob("tasks/*.md"))],
]


def load_file(path: str) -> str:
    return (REPO_ROOT / path).read_text()


def parse_frontmatter_field(path: str, field: str) -> str | None:
    """Extract a single YAML frontmatter field value from a Markdown file."""
    content = load_file(path)
    if not content.startswith("---"):
        return None
    end = content.find("\n---", 3)
    if end == -1:
        return None
    frontmatter = content[3:end]
    match = re.search(rf"^{re.escape(field)}:\s*(.+)", frontmatter, re.MULTILINE)
    return match.group(1).strip() if match else None


def parse_frontmatter_model(path: str) -> str | None:
    return parse_frontmatter_field(path, "model")


class TestTaskFileExistence:
    """Referenced task files must exist on disk."""

    def test_code_exists(self):
        assert (REPO_ROOT / "tasks/code.md").exists()

    def test_status_correction_exists(self):
        assert (REPO_ROOT / "tasks/status-correction.md").exists()


class TestPlanRoutingTable:
    """
    Plan routing table must cover every important decision branch.
    Removing or renaming a branch should cause one of these tests to fail.
    """

    def test_routing_covers_demo_review_approved(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"demo-review-complete.*approved", content, re.IGNORECASE), (
            "Plan routing table must handle demo-review-complete approved"
        )

    def test_routing_covers_demo_review_redirect(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"demo-review-complete.*redirect", content, re.IGNORECASE), (
            "Plan routing table must handle demo-review-complete redirect"
        )

    def test_routing_covers_test_pass(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"test-complete.*pass", content, re.IGNORECASE), (
            "Plan routing table must handle test-complete pass"
        )

    def test_routing_covers_test_fail(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"test-complete.*fail", content, re.IGNORECASE), (
            "Plan routing table must handle test-complete fail"
        )

    def test_routing_covers_stale_implementation(self):
        content = load_file("tasks/plan.md")
        assert "stale" in content.lower(), (
            "Plan routing table must handle the stale-implementation case "
            "(issue updated after test passed)"
        )

    def test_routing_covers_task_complete_with_open_pr(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"task-complete.*exists", content, re.IGNORECASE), (
            "Plan routing table must handle task-complete with open PR"
        )

    def test_routing_covers_task_complete_with_broken_ci(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"CI failing|CI green", content, re.IGNORECASE), (
            "Plan routing table must distinguish CI green vs failing states"
        )

    def test_routing_covers_no_work_done(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"No.*task-complete|no.*task-complete", content), (
            "Plan routing table must handle the case where no work has been done yet"
        )

    def test_routing_covers_branch_exists_no_pr(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"[Bb]ranch exists", content), (
            "Plan routing table must handle branch-exists-but-no-PR state"
        )

    def test_plan_defines_next_task_values(self):
        content = load_file("tasks/plan.md")
        for value in ["code", "test", "demo-review"]:
            assert value in content, f"plan.md must document next_task value: {value}"

    def test_routing_covers_merge_conflicts(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"merge.conflict", content, re.IGNORECASE), (
            "Plan routing table must handle the case where a PR has merge conflicts"
        )

    def test_plan_checks_mergeability(self):
        content = load_file("tasks/plan.md")
        assert "mergeable" in content.lower(), (
            "plan.md must instruct the agent to check PR mergeability (e.g. via gh pr view --json mergeable)"
        )


class TestMergeConflictHandling:
    """Merge conflict detection and resolution must be covered in code.md."""

    def test_code_instructs_conflict_resolution_on_rebase(self):
        content = load_file("tasks/code.md")
        assert re.search(r"conflict", content, re.IGNORECASE), (
            "code.md must instruct the agent to resolve merge conflicts during rebase"
        )

    def test_code_instructs_task_failed_on_unresolvable_conflicts(self):
        content = load_file("tasks/code.md")
        assert "task-failed" in content, (
            "code.md must instruct the agent to report task-failed when conflicts cannot be resolved"
        )
        assert re.search(r"conflict", content, re.IGNORECASE), (
            "code.md must mention conflicts in the context of task-failed reporting"
        )


class TestInputOutputChain:
    """
    Fields produced by one task must be consumed by the appropriate downstream task.
    A missing field in the producer or consumer breaks the hand-off.
    """

    def test_plan_outputs_branch_consumed_by_implement(self):
        assert "branch" in load_file("tasks/plan.md")
        assert "branch" in load_file("tasks/code.md")

    def test_plan_outputs_findings_consumed_by_implement(self):
        assert "findings" in load_file("tasks/plan.md")
        assert "findings" in load_file("tasks/code.md")

    def test_implement_outputs_pr_url_consumed_by_test(self):
        assert "pr_url" in load_file("tasks/code.md")
        assert "pr_url" in load_file("tasks/test.md")

    def test_test_outputs_issue_id_consumed_by_demo_review(self):
        assert "issue_id" in load_file("tasks/test.md")
        assert "issue_id" in load_file("tasks/demo-review.md")

    def test_demo_review_outputs_user_feedback_consumed_by_implement(self):
        assert "user_feedback" in load_file("tasks/demo-review.md")
        assert "user_feedback" in load_file("tasks/code.md")


class TestReportSchemas:
    """Each task must define its complete output report schema."""

    def test_triage_defines_report_schema(self):
        content = load_file("tasks/issue-triage.md")
        assert "triage-report" in content
        assert "next_issue" in content

    def test_plan_defines_report_schema(self):
        content = load_file("tasks/plan.md")
        assert "plan-report" in content
        assert "next_task" in content
        assert "issue_id" in content

    def test_code_defines_task_complete(self):
        content = load_file("tasks/code.md")
        assert "task-complete" in content
        assert "pr_url" in content
        assert "summary" in content

    def test_code_defines_task_failed(self):
        content = load_file("tasks/code.md")
        assert "task-failed" in content
        assert "failure" in content

    def test_test_defines_test_report(self):
        content = load_file("tasks/test.md")
        assert "test-report" in content
        assert "outcome" in content
        assert "findings" in content

    def test_triage_defines_task_failed(self):
        content = load_file("tasks/issue-triage.md")
        assert "task-failed" in content
        assert "failure" in content

    def test_demo_review_defines_pending_report(self):
        content = load_file("tasks/demo-review.md")
        assert "demo-review-pending" in content

    def test_create_issue_supports_priority_field(self):
        content = load_file("tasks/create-issue.md")
        assert "priority" in content, (
            "tasks/create-issue.md must support an optional priority field"
        )


class TestMultiPRHandling:
    """
    Verify that multi-PR tracking is documented in plan.md and demo-review.md.
    """

    def test_plan_mentions_multi_pr_handling(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"all.*PR|associated PR|multi-PR", content, re.IGNORECASE), (
            "tasks/plan.md must mention multi-PR handling (e.g., 'all PRs', 'associated PRs', or 'multi-PR')"
        )

    def test_plan_mentions_all_prs_merged_or_closed(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"all.*(?:PRs|associated).*(?:merged|closed)", content, re.IGNORECASE), (
            "tasks/plan.md routing table must require all associated PRs to be merged or closed"
        )

    def test_plan_handles_remaining_open_prs(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"other.*PR.*open|remaining.*PR|associated PRs still open", content, re.IGNORECASE), (
            "tasks/plan.md routing table must handle the case where some associated PRs are still open "
            "(multi-PR tracking moved from demo-review to plan.md)"
        )


class TestDemoReviewApprovalGate:
    """demo-review.md must delegate approval to the orchestrator and never self-merge."""

    def test_demo_review_prohibits_merge(self):
        content = load_file("tasks/demo-review.md")
        assert re.search(r"NEVER merge", content), (
            "demo-review.md must explicitly prohibit the agent from merging the PR"
        )

    def test_demo_review_prohibits_ask_user_question(self):
        content = load_file("tasks/demo-review.md")
        assert re.search(r"NOT call.*AskUserQuestion|Do NOT call.*AskUserQuestion|NEVER.*AskUserQuestion", content), (
            "demo-review.md must prohibit AskUserQuestion — approval is handled by the orchestrator"
        )


class TestModelSpecification:
    """Every task must specify a valid model in YAML frontmatter."""

    def test_all_files_have_frontmatter_model(self):
        for path in TASK_FILES:
            model = parse_frontmatter_model(path)
            assert model is not None, f"{path} is missing a 'model:' field in YAML frontmatter"

    def test_all_models_are_valid(self):
        for path in TASK_FILES:
            model = parse_frontmatter_model(path)
            assert model in VALID_MODELS, (
                f"{path} specifies unknown model '{model}'; must be one of {sorted(VALID_MODELS)}"
            )


class TestSessionPersistence:
    """Session persistence: config file must be well-formed and in the install manifest."""

    def test_default_config_exists(self):
        config_path = REPO_ROOT / "config" / "default-config.json"
        assert config_path.exists(), "config/default-config.json template must exist"

    def test_default_config_is_valid_json(self):
        config_path = REPO_ROOT / "config" / "default-config.json"
        content = config_path.read_text()
        data = json.loads(content)
        assert "project_url" in data, "default-config.json must contain project_url field"
        assert "system" in data, "default-config.json must contain system field"

    def test_config_in_package_files(self):
        content = load_file("package.json")
        data = json.loads(content)
        assert "config/" in data.get("files", []), (
            "package.json files array must include config/"
        )

    def test_status_shows_config_state(self):
        content = load_file("lib/install.js")
        assert "configStatus" in content or "config" in content.lower(), (
            "status() function must display config state"
        )


class TestQAPreflightBehavior:
    """QA task must include a pre-flight env setup check that blocks before testing."""

    def test_test_has_preflight_step(self):
        content = load_file("tasks/test.md")
        assert "pre-flight" in content.lower(), (
            "tasks/test.md must include a pre-flight step"
        )

    def test_test_defines_qa_blocked_report(self):
        content = load_file("tasks/test.md")
        assert "qa-blocked-missing-env-setup" in content, (
            "tasks/test.md must define the qa-blocked-missing-env-setup report type"
        )
        assert "issue_id" in content, (
            "tasks/test.md qa-blocked report must include issue_id"
        )
        assert "pr_url" in content, (
            "tasks/test.md qa-blocked report must include pr_url"
        )
        assert "missing" in content, (
            "tasks/test.md qa-blocked report must include missing field"
        )

    def test_test_preflight_blocks_before_testing(self):
        content = load_file("tasks/test.md")
        assert "stop immediately" in content.lower() or "do not proceed" in content.lower(), (
            "tasks/test.md pre-flight must block before normal test steps "
            "(should contain 'stop immediately' or 'do not proceed')"
        )


class TestSplitReport:
    """Split-report schema must be fully defined in plan.md and create-issue.md."""

    def test_plan_defines_split_report_type(self):
        content = load_file("tasks/plan.md")
        assert "split-report" in content, "plan.md must define the split-report message type"

    def test_plan_defines_scope_assessment(self):
        content = load_file("tasks/plan.md")
        assert re.search(r"scope|too big|single PR", content, re.IGNORECASE), (
            "plan.md must include a scope assessment step explaining when an issue is too big for a single PR"
        )

    def test_plan_split_report_has_required_fields(self):
        content = load_file("tasks/plan.md")
        for field in ["source_issue_id", "reason", "issues", "depends_on"]:
            assert field in content, f"plan.md split-report schema is missing field: {field}"

    def test_create_issue_accepts_and_echoes_context(self):
        content = load_file("tasks/create-issue.md")
        assert "context" in content, (
            "create-issue.md must accept and echo the optional context field"
        )
