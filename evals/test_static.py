"""
Static structural checks — no API calls, runs in milliseconds.

These tests verify that the task definition files are internally consistent:
- All referenced task files exist
- The plan routing table covers all required decision branches
- Input/output fields chain correctly between tasks
- Every task defines an output report schema
- The team manager handles every report type any task can produce
- Every task and role specifies the correct model in its frontmatter
"""
import re
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent

VALID_MODELS = {"claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"}

ROLE_AND_TASK_FILES = [
    *[p.relative_to(REPO_ROOT) for p in sorted(REPO_ROOT.glob("roles/*.md"))],
    *[p.relative_to(REPO_ROOT) for p in sorted(REPO_ROOT.glob("tasks/*.md"))],
]


def load_file(path: str) -> str:
    return (REPO_ROOT / path).read_text()


def parse_frontmatter_model(path: str) -> str | None:
    content = load_file(path)
    if not content.startswith("---"):
        return None
    end = content.find("\n---", 3)
    if end == -1:
        return None
    frontmatter = content[3:end]
    match = re.search(r"^model:\s*(\S+)", frontmatter, re.MULTILINE)
    return match.group(1) if match else None


class TestTaskFileExistence:
    """All task files referenced in team-manager.md must exist on disk."""

    def test_all_referenced_tasks_exist(self):
        manager_content = load_file("roles/team-manager.md")
        task_paths = re.findall(r"`(tasks/[\w\-]+\.md)`", manager_content)
        assert task_paths, "No task paths found in team-manager.md Available Tasks table"
        for path in task_paths:
            assert (REPO_ROOT / path).exists(), f"Task file referenced but missing: {path}"

    def test_implement_frontend_exists(self):
        assert (REPO_ROOT / "tasks/implement-frontend.md").exists()

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
        for value in ["implement-backend", "implement-frontend", "implement-both", "test", "demo-review"]:
            assert value in content, f"plan.md must document next_task value: {value}"


class TestInputOutputChain:
    """
    Fields produced by one task must be consumed by the appropriate downstream task.
    A missing field in the producer or consumer breaks the hand-off.
    """

    def test_plan_outputs_branch_consumed_by_implement(self):
        assert "branch" in load_file("tasks/plan.md")
        assert "branch" in load_file("tasks/implement-backend.md")
        assert "branch" in load_file("tasks/implement-frontend.md")

    def test_plan_outputs_worktree_consumed_by_implement(self):
        assert "worktree" in load_file("tasks/plan.md")
        assert "worktree" in load_file("tasks/implement-backend.md")
        assert "worktree" in load_file("tasks/implement-frontend.md")

    def test_plan_outputs_findings_consumed_by_implement(self):
        assert "findings" in load_file("tasks/plan.md")
        assert "findings" in load_file("tasks/implement-backend.md")

    def test_implement_outputs_pr_url_consumed_by_test(self):
        assert "pr_url" in load_file("tasks/implement-backend.md")
        assert "pr_url" in load_file("tasks/test.md")

    def test_test_outputs_findings_consumed_by_manager_routing(self):
        # Manager must pass findings back to implementer on failure
        assert "findings" in load_file("tasks/test.md")
        assert "findings" in load_file("roles/team-manager.md")

    def test_test_outputs_issue_id_consumed_by_demo_review(self):
        assert "issue_id" in load_file("tasks/test.md")
        assert "issue_id" in load_file("tasks/demo-review.md")

    def test_demo_review_outputs_user_feedback_consumed_by_implement(self):
        assert "user_feedback" in load_file("tasks/demo-review.md")
        assert "user_feedback" in load_file("tasks/implement-backend.md")

    def test_triage_outputs_next_issue_referenced_by_manager(self):
        assert "next_issue" in load_file("tasks/issue-triage.md")
        assert "next_issue" in load_file("roles/team-manager.md")


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

    def test_implement_backend_defines_task_complete(self):
        content = load_file("tasks/implement-backend.md")
        assert "task-complete" in content
        assert "pr_url" in content
        assert "summary" in content

    def test_implement_backend_defines_task_failed(self):
        content = load_file("tasks/implement-backend.md")
        assert "task-failed" in content
        assert "failure" in content

    def test_test_defines_test_report(self):
        content = load_file("tasks/test.md")
        assert "test-report" in content
        assert "outcome" in content
        assert "findings" in content

    def test_demo_review_defines_demo_review_report(self):
        content = load_file("tasks/demo-review.md")
        assert "demo-review-report" in content
        assert "outcome" in content
        assert "user_feedback" in content

    def test_team_member_defines_blocked_schema(self):
        content = load_file("roles/team-member.md")
        assert "blocked" in content
        assert "what_is_blocked" in content
        assert "decision_needed" in content
        assert "what_was_tried" in content


class TestManagerHandlesAllReports:
    """Team Manager must handle every report type any task can produce."""

    def test_manager_handles_triage_report(self):
        content = load_file("roles/team-manager.md")
        assert "triage report" in content.lower() or "triage-report" in content

    def test_manager_handles_plan_report(self):
        content = load_file("roles/team-manager.md")
        assert "plan-report" in content

    def test_manager_handles_task_complete(self):
        content = load_file("roles/team-manager.md")
        assert "task-complete" in content

    def test_manager_handles_task_failed(self):
        content = load_file("roles/team-manager.md")
        assert "task-failed" in content

    def test_manager_handles_test_report(self):
        content = load_file("roles/team-manager.md")
        assert "test-report" in content

    def test_manager_handles_demo_review_report(self):
        content = load_file("roles/team-manager.md")
        assert "demo-review-report" in content

    def test_manager_handles_blocked(self):
        content = load_file("roles/team-manager.md")
        assert "blocker" in content.lower() or "blocked" in content.lower()

    def test_manager_handles_status_correction_report(self):
        content = load_file("roles/team-manager.md")
        assert "status-correction-report" in content


class TestModelSpecification:
    """Every task and role must specify a valid model in YAML frontmatter."""

    def test_all_files_have_frontmatter_model(self):
        for path in ROLE_AND_TASK_FILES:
            model = parse_frontmatter_model(path)
            assert model is not None, f"{path} is missing a 'model:' field in YAML frontmatter"

    def test_all_models_are_valid(self):
        for path in ROLE_AND_TASK_FILES:
            model = parse_frontmatter_model(path)
            assert model in VALID_MODELS, (
                f"{path} specifies unknown model '{model}'; must be one of {sorted(VALID_MODELS)}"
            )
