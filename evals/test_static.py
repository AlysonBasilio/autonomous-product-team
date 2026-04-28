"""
Static structural checks — no API calls, runs in milliseconds.

These tests verify that the task definition files are internally consistent:
- All referenced task files exist
- The plan routing table covers all required decision branches
- Input/output fields chain correctly between tasks
- Every task defines an output report schema
- The team lead handles every report type any task can produce
- Every task and role specifies the correct model in its frontmatter
- The installer configures the TeammateIdle hook to stop idle teammates
- Session persistence config and hooks are properly defined
"""
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent

VALID_MODELS = {"claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"}

ROLE_AND_TASK_FILES = [
    *[p.relative_to(REPO_ROOT) for p in sorted(REPO_ROOT.glob("roles/*.md"))],
    *[p.relative_to(REPO_ROOT) for p in sorted(REPO_ROOT.glob("tasks/*.md"))],
]

SKILL_FILES = [
    p.relative_to(REPO_ROOT)
    for p in sorted(REPO_ROOT.glob(".claude/skills/*/SKILL.md"))
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
    """All task files referenced in team-lead.md must exist on disk."""

    def test_all_referenced_tasks_exist(self):
        lead_content = load_file("roles/team-lead.md")
        task_paths = re.findall(r"`(tasks/[\w\-]+\.md)`", lead_content)
        assert task_paths, "No task paths found in team-lead.md Available Tasks table"
        for path in task_paths:
            assert (REPO_ROOT / path).exists(), f"Task file referenced but missing: {path}"

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
    """Merge conflict detection and resolution must be covered end-to-end."""

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

    def test_demo_review_checks_mergeability_before_merge(self):
        content = load_file("tasks/demo-review.md")
        assert "mergeable" in content.lower(), (
            "demo-review.md must check PR mergeability before attempting to merge"
        )

    def test_demo_review_blocks_merge_on_conflict(self):
        content = load_file("tasks/demo-review.md")
        assert re.search(r"CONFLICTING|conflict", content, re.IGNORECASE), (
            "demo-review.md must explicitly block merge when the PR has merge conflicts"
        )


class TestInputOutputChain:
    """
    Fields produced by one task must be consumed by the appropriate downstream task.
    A missing field in the producer or consumer breaks the hand-off.
    """

    def test_plan_outputs_branch_consumed_by_implement(self):
        assert "branch" in load_file("tasks/plan.md")
        assert "branch" in load_file("tasks/code.md")

    def test_plan_outputs_worktree_consumed_by_implement(self):
        assert "worktree" in load_file("tasks/plan.md")
        assert "worktree" in load_file("tasks/code.md")

    def test_plan_outputs_findings_consumed_by_implement(self):
        assert "findings" in load_file("tasks/plan.md")
        assert "findings" in load_file("tasks/code.md")

    def test_implement_outputs_pr_url_consumed_by_test(self):
        assert "pr_url" in load_file("tasks/code.md")
        assert "pr_url" in load_file("tasks/test.md")

    def test_test_outputs_findings_consumed_by_manager_routing(self):
        # Manager must pass findings back to implementer on failure
        assert "findings" in load_file("tasks/test.md")
        assert "findings" in load_file("roles/team-lead.md")

    def test_test_outputs_issue_id_consumed_by_demo_review(self):
        assert "issue_id" in load_file("tasks/test.md")
        assert "issue_id" in load_file("tasks/demo-review.md")

    def test_demo_review_outputs_user_feedback_consumed_by_implement(self):
        assert "user_feedback" in load_file("tasks/demo-review.md")
        assert "user_feedback" in load_file("tasks/code.md")

    def test_triage_outputs_next_issue_referenced_by_manager(self):
        assert "next_issue" in load_file("tasks/issue-triage.md")
        assert "next_issue" in load_file("roles/team-lead.md")


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

    def test_demo_review_defines_demo_review_report(self):
        content = load_file("tasks/demo-review.md")
        assert "demo-review-report" in content
        assert "outcome" in content
        assert "user_feedback" in content

    def test_teammate_defines_blocked_schema(self):
        content = load_file("roles/teammate.md")
        assert "blocked" in content
        assert "what_is_blocked" in content
        assert "decision_needed" in content
        assert "what_was_tried" in content

    def test_create_issue_supports_priority_field(self):
        content = load_file("tasks/create-issue.md")
        assert "priority" in content, (
            "tasks/create-issue.md must support an optional priority field"
        )


class TestManagerHandlesAllReports:
    """Team Lead must handle every report type any task can produce."""

    def test_manager_handles_triage_report(self):
        content = load_file("roles/team-lead.md")
        assert "triage report" in content.lower() or "triage-report" in content

    def test_manager_handles_plan_report(self):
        content = load_file("roles/team-lead.md")
        assert "plan-report" in content

    def test_manager_handles_task_complete(self):
        content = load_file("roles/team-lead.md")
        assert "task-complete" in content

    def test_manager_handles_task_failed(self):
        content = load_file("roles/team-lead.md")
        assert "task-failed" in content

    def test_manager_handles_test_report(self):
        content = load_file("roles/team-lead.md")
        assert "test-report" in content

    def test_manager_handles_demo_review_report(self):
        content = load_file("roles/team-lead.md")
        assert "demo-review-report" in content

    def test_manager_handles_blocked(self):
        content = load_file("roles/team-lead.md")
        assert "blocker" in content.lower() or "blocked" in content.lower()

    def test_manager_handles_status_correction_report(self):
        content = load_file("roles/team-lead.md")
        assert "status-correction-report" in content

    def test_manager_handles_qa_blocked_missing_env_setup(self):
        content = load_file("roles/team-lead.md")
        assert "qa-blocked-missing-env-setup" in content, (
            "roles/team-lead.md must handle the qa-blocked-missing-env-setup report"
        )


class TestHooksExistence:
    """Hook scripts must exist on disk and be referenced in the installer."""

    HOOK_SCRIPTS = [
        "hooks/guard-destructive-git.sh",
        "hooks/guard-worktree-discipline.sh",
        "hooks/load-session-context.sh",
        "hooks/log-agent-event.sh",
    ]

    def test_all_hook_scripts_exist(self):
        for script in self.HOOK_SCRIPTS:
            assert (REPO_ROOT / script).exists(), f"Hook script missing: {script}"

    def test_hook_scripts_are_executable(self):
        import os
        for script in self.HOOK_SCRIPTS:
            filepath = REPO_ROOT / script
            assert os.access(filepath, os.X_OK), f"Hook script not executable: {script}"

    def test_hooks_in_install_manifest(self):
        content = load_file("lib/install.js")
        for script in self.HOOK_SCRIPTS:
            assert script in content, f"Hook script not in MANIFEST: {script}"

    def test_hooks_config_in_required_settings(self):
        content = load_file("lib/install.js")
        assert "'hooks'" in content or '"hooks"' in content or "hooks:" in content, (
            "REQUIRED_SETTINGS must include a hooks configuration"
        )
        # Verify specific hook events are configured
        for event in ["PreToolUse", "SessionStart", "SubagentStart", "SubagentStop"]:
            assert event in content, f"REQUIRED_SETTINGS hooks must include {event}"

    def test_hooks_in_package_files(self):
        content = load_file("package.json")
        assert "hooks/" in content, "package.json files must include hooks/"


class TestMultiPRHandling:
    """
    Verify that multi-PR tracking is documented across the relevant files:
    plan.md, demo-review.md, and team-lead.md.
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

    def test_team_lead_handles_no_next_task(self):
        content = load_file("roles/team-lead.md")
        assert re.search(r"no.{0,20}next_task|no `next_task`", content, re.IGNORECASE), (
            "roles/team-lead.md must handle plan-report with no next_task "
            "(issued when issue is Done or awaiting user merge)"
        )


class TestDemoReviewSyncAndApprovalGate:
    """Both copies of demo-review.md must stay in sync and require explicit user approval."""

    def test_demo_review_copies_in_sync(self):
        primary = (REPO_ROOT / "tasks/demo-review.md").read_text()
        secondary = (REPO_ROOT / ".claude/product-team/tasks/demo-review.md").read_text()
        assert primary == secondary, (
            "tasks/demo-review.md and .claude/product-team/tasks/demo-review.md are out of sync"
        )

    def test_demo_review_requires_ask_user_question(self):
        content = load_file("tasks/demo-review.md")
        assert "AskUserQuestion" in content, (
            "demo-review.md must reference AskUserQuestion as the required approval mechanism"
        )

    def test_demo_review_prohibits_merge_without_user_approval(self):
        content = load_file("tasks/demo-review.md")
        assert re.search(r"NEVER merge", content), (
            "demo-review.md Rules section must explicitly prohibit the agent from merging the PR"
        )

    def test_demo_review_ci_not_approval(self):
        content = load_file("tasks/demo-review.md")
        assert re.search(r"CI.{0,10}NOT approval|NOT approval", content) and re.search(r"CI pass|CI green", content), (
            "demo-review.md must explicitly state that CI passing/green is NOT approval"
        )


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


def _load_required_settings():
    """Parse REQUIRED_SETTINGS from lib/install.js using AST-free text extraction."""
    install_js = (REPO_ROOT / "lib" / "install.js").read_text()
    return install_js


class TestIdleTeammateHook:
    """The installer must configure TeammateIdle so idle teammates are stopped automatically."""

    def test_required_settings_includes_teammate_idle_hook(self):
        install_js = _load_required_settings()
        assert "TeammateIdle" in install_js, (
            "lib/install.js REQUIRED_SETTINGS must include a TeammateIdle hook "
            "to automatically stop idle teammates"
        )

    def test_idle_hook_stops_teammate(self):
        install_js = _load_required_settings()
        assert re.search(r'"continue"\s*:\s*false', install_js), (
            'lib/install.js TeammateIdle hook must output {"continue": false} to stop idle teammates'
        )

    def test_team_lead_role_mentions_idle_hook(self):
        content = load_file("roles/team-lead.md")
        assert "TeammateIdle" in content or "idle" in content.lower(), (
            "roles/team-lead.md must document that idle teammates are removed after reporting"
        )


class TestSessionStartHookExitsCleanly:
    """The second SessionStart hook must always exit 0, even when config.json is missing."""

    def test_session_start_uses_if_guard_not_bare_and(self):
        content = load_file("lib/install.js")
        # Find the SessionStart hook command that reads config.json
        assert re.search(r'if \[ -f .claude/product-team/config\.json \]', content), (
            "lib/install.js SessionStart hook must use 'if [ -f ... ]' guard "
            "instead of bare 'test -f ... &&' to avoid non-zero exit when config is missing"
        )

    def test_session_start_config_hook_ends_with_fi(self):
        content = load_file("lib/install.js")
        # The command should end with 'fi' (inside the template string)
        assert re.search(r'config\.json.*fi[`"\']', content), (
            "lib/install.js SessionStart config hook command must end with 'fi' "
            "to ensure the if-block always exits 0"
        )

    def test_session_start_node_never_exits_nonzero(self):
        content = load_file("lib/install.js")
        # The inline node command must not use process.exit(1) for unconfigured state;
        # a null project_url (fresh install) must exit 0, not 1.
        assert "process.exit(1)" not in content, (
            "lib/install.js SessionStart hook must never use process.exit(1); "
            "unconfigured state (project_url is null) must exit 0 to avoid hook errors"
        )


class TestWorktreeHookClaudioExemption:
    """The worktree discipline hook must exempt .claude/ paths (metadata/config)."""

    def test_worktree_hook_allows_claude_paths(self):
        content = load_file("hooks/guard-worktree-discipline.sh")
        assert ".claude/" in content, (
            "guard-worktree-discipline.sh must contain an exemption for .claude/ paths"
        )

    def test_worktree_hook_exits_early_for_claude_paths(self):
        content = load_file("hooks/guard-worktree-discipline.sh")
        # The exemption should exit 0 (allow the write)
        assert re.search(r'\.claude/.*exit 0', content, re.DOTALL), (
            "guard-worktree-discipline.sh must exit 0 for .claude/ paths to allow config writes"
        )


class TestTeamMemberIdleWarning:
    """Team member role must warn agents that going idle will terminate their session."""

    def test_teammate_warns_about_idle_termination(self):
        content = load_file("roles/teammate.md")
        assert "TeammateIdle" in content, (
            "roles/teammate.md must mention TeammateIdle hook so agents know they will be terminated"
        )

    def test_teammate_requires_continuous_session(self):
        content = load_file("roles/teammate.md")
        assert re.search(r"single continuous session|never go idle", content, re.IGNORECASE), (
            "roles/teammate.md must instruct agents to complete work in a single continuous session"
        )


class TestSessionPersistence:
    """Session persistence: config file, SessionStart hook, and manager startup."""

    def test_default_config_exists(self):
        config_path = REPO_ROOT / "config" / "default-config.json"
        assert config_path.exists(), "config/default-config.json template must exist"

    def test_default_config_is_valid_json(self):
        config_path = REPO_ROOT / "config" / "default-config.json"
        content = config_path.read_text()
        data = json.loads(content)
        assert "project_url" in data, "default-config.json must contain project_url field"
        assert "system" in data, "default-config.json must contain system field"

    def test_config_in_install_manifest(self):
        content = load_file("lib/install.js")
        assert "config/default-config.json" in content, (
            "install.js MANIFEST must include config/default-config.json"
        )
        assert ".claude/product-team/config.json" in content, (
            "install.js must install config to .claude/product-team/config.json"
        )

    def test_session_start_hook_in_settings(self):
        content = load_file("lib/install.js")
        assert "SessionStart" in content, (
            "install.js REQUIRED_SETTINGS must include a SessionStart hook"
        )

    def test_config_in_package_files(self):
        content = load_file("package.json")
        data = json.loads(content)
        assert "config/" in data.get("files", []), (
            "package.json files array must include config/"
        )

    def test_manager_reads_saved_config(self):
        content = load_file("roles/team-lead.md")
        assert "config.json" in content, (
            "team-lead.md startup must reference config.json"
        )
        assert "project_url" in content, (
            "team-lead.md startup must reference project_url from saved config"
        )

    def test_manager_saves_config_on_first_run(self):
        content = load_file("roles/team-lead.md")
        assert re.search(r"[Ss]ave.*config", content), (
            "team-lead.md must instruct saving config on first run"
        )

    def test_manager_skips_asking_when_config_exists(self):
        content = load_file("roles/team-lead.md")
        assert re.search(r"skip.*asking|only if no saved config", content, re.IGNORECASE), (
            "team-lead.md must skip asking when saved config exists"
        )

    def test_session_hook_reads_correct_config_fields(self):
        """The SessionStart hook must read the same field names defined in default-config.json."""
        config_path = REPO_ROOT / "config" / "default-config.json"
        config_data = json.loads(config_path.read_text())
        hook_content = load_file("hooks/load-session-context.sh")
        for field in config_data:
            assert f".{field}" in hook_content, (
                f"load-session-context.sh must read .{field} from config "
                f"(field defined in default-config.json)"
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


class TestSkillFrontmatter:
    """Every installed skill must declare name and description in YAML frontmatter."""

    def test_skill_files_found(self):
        assert SKILL_FILES, "No SKILL.md files found under .claude/skills/"

    def test_all_skills_have_name(self):
        for path in SKILL_FILES:
            name = parse_frontmatter_field(path, "name")
            assert name is not None, f"{path} is missing a 'name:' field in YAML frontmatter"

    def test_all_skills_have_description(self):
        for path in SKILL_FILES:
            desc = parse_frontmatter_field(path, "description")
            assert desc is not None, f"{path} is missing a 'description:' field in YAML frontmatter"

    def test_skill_name_matches_directory(self):
        for path in SKILL_FILES:
            name = parse_frontmatter_field(path, "name")
            dir_name = path.parent.name
            assert name == dir_name, (
                f"{path}: skill name '{name}' does not match directory name '{dir_name}'"
            )
