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
    "anthropic/claude-opus-4-7",
    "anthropic/claude-sonnet-4-6",
    "anthropic/claude-haiku-4.5",
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
    """Session persistence: config is submitted via the web UI and persists in
    orchestrator-state.json. The orchestrator must wait for a complete config
    before dispatching tasks, and `install.js status` must surface it."""

    def test_server_defines_required_config_keys(self):
        content = load_file("orchestrator/server.rb")
        assert "CONFIG_KEYS" in content, (
            "orchestrator/server.rb must define CONFIG_KEYS for session config"
        )
        for key in ("project_url", "tenant", "api_key"):
            assert key in content, (
                f"orchestrator/server.rb must reference required config key '{key}'"
            )

    def test_config_persists_to_state_file(self):
        content = load_file("orchestrator/server.rb")
        assert "/api/config" in content, (
            "orchestrator/server.rb must expose POST /api/config"
        )
        assert "State.patch" in content and "'config'" in content, (
            "POST /api/config must persist submitted values into orchestrator-state.json"
        )

    def test_run_waits_for_config_before_dispatch(self):
        content = load_file("orchestrator/run.rb")
        assert "config_complete?" in content, (
            "orchestrator/run.rb must gate task dispatch on config_complete?"
        )

    def test_status_shows_config_state(self):
        content = load_file("lib/install.js")
        assert "orchestrator-state.json" in content and "config" in content.lower(), (
            "install.js status() must read config state from orchestrator-state.json"
        )


class TestQABlockedDelegation:
    """
    When the QA agent cannot run the app itself, it must hand the test to
    the user via a `test-blocked` report. The orchestrator routes this to
    the wait-approval gate — there is no more pre-flight doc scan.
    """

    def test_test_defines_test_blocked_report(self):
        content = load_file("tasks/test.md")
        assert "test-blocked" in content, (
            "tasks/test.md must define the test-blocked report type"
        )
        assert "issue_id" in content, (
            "tasks/test.md test-blocked report must include issue_id"
        )
        assert "pr_url" in content, (
            "tasks/test.md test-blocked report must include pr_url"
        )
        assert "summary" in content, (
            "tasks/test.md test-blocked report must include a summary "
            "(matches router.rb's report['summary'] read)"
        )

    def test_test_attempts_before_delegating(self):
        content = load_file("tasks/test.md").lower()
        assert "try to" in content or "attempt" in content, (
            "tasks/test.md must instruct the agent to try running the app itself "
            "before handing off to the user"
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


# Mirrored from orchestrator/task_runner.rb — keep in sync.
KNOWN_REPORT_TYPES = {
    "triage-report", "plan-report", "task-complete", "split-report", "test-report",
    "demo-review-pending", "demo-review-report", "discovery-complete",
    "create-issue-complete", "status-correction-report",
    "test-blocked", "task-failed", "blocked",
}

# Report types that agents author in task specs. demo-review-report is constructed
# by orchestrator/run.rb after UI approval, never by an agent — so it isn't expected
# to appear as a fenced JSON example in any task spec.
EXPECTED_AGENT_REPORT_TYPES = KNOWN_REPORT_TYPES - {"demo-review-report"}

# Types not authored in any task spec today (router-only handlers).
TYPES_NOT_IN_TASK_SPECS = {"blocked"}


def _fenced_json_blocks(content: str) -> list[dict]:
    """Return every fenced ```json block in content that successfully JSON-parses."""
    blocks = []
    for match in re.finditer(r"^[ \t]*```json\n(.*?)\n[ \t]*```", content, re.DOTALL | re.MULTILINE):
        try:
            blocks.append(json.loads(match.group(1)))
        except json.JSONDecodeError:
            continue
    return blocks


class TestReportFormatIsJson:
    """
    Each agent-authored report block in tasks/*.md must be fenced ```json and
    parse as valid JSON. Regression guard against drift back to YAML-ish format.

    Fixtures use angle-bracket placeholders like "<issue ID>" — JSON parsing
    treats those as plain strings, so the example payloads must already be
    syntactically valid JSON.
    """

    def test_every_known_report_type_appears_in_a_task_spec(self):
        """Every agent-emitted report type must be authored as a fenced JSON example."""
        types_seen: set[str] = set()
        for task_path in TASK_FILES:
            for block in _fenced_json_blocks(load_file(str(task_path))):
                if isinstance(block, dict) and "type" in block:
                    types_seen.add(block["type"])

        expected = EXPECTED_AGENT_REPORT_TYPES - TYPES_NOT_IN_TASK_SPECS
        missing = expected - types_seen
        assert not missing, (
            f"Report types missing a fenced ```json example in tasks/*.md: {sorted(missing)}. "
            f"Each agent-emitted report type must have a JSON example so the "
            f"orchestrator's extract_report can match it."
        )

    def test_every_fenced_json_block_in_task_specs_parses(self):
        """Every ```json block in tasks/*.md must parse — no malformed JSON examples."""
        for task_path in TASK_FILES:
            content = load_file(str(task_path))
            for match in re.finditer(r"^[ \t]*```json\n(.*?)\n[ \t]*```", content, re.DOTALL | re.MULTILINE):
                try:
                    json.loads(match.group(1))
                except json.JSONDecodeError as e:
                    raise AssertionError(
                        f"{task_path} contains a ```json block that does not parse: {e}\n"
                        f"Block:\n{match.group(1)}"
                    )

    def test_no_yaml_style_report_blocks_remain(self):
        """
        Catch the old YAML-ish ` ```\\ntype: foo\\n... ` shape that the
        orchestrator's extract_report cannot match (this is the bug that
        caused issue-triage to time out at 30 minutes).
        """
        # Pattern: a fenced block (no language tag, or any tag other than json)
        # whose first line is `type: <known-report-type>`.
        type_alternation = "|".join(re.escape(t) for t in EXPECTED_AGENT_REPORT_TYPES)
        bad_pattern = re.compile(
            r"```(?!json\n)[a-z]*\n\s*type:\s*(" + type_alternation + r")\b",
            re.MULTILINE,
        )
        for task_path in TASK_FILES:
            content = load_file(str(task_path))
            match = bad_pattern.search(content)
            assert not match, (
                f"{task_path} still has a YAML-style report block (`type: {match.group(1)}` "
                f"inside a non-json fence). The orchestrator's extract_report only matches "
                f"fenced ```json blocks — convert this to JSON."
            )
