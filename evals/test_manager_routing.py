"""
LLM-as-judge evals for Team Manager routing decisions.

Each scenario delivers a specific inbound message to the manager and verifies
that the manager's next action matches the routing rules in team-manager.md.

Requires OPENROUTER_API_KEY.
"""
import pytest

from conftest import load_task, parse_frontmatter_model
from judge import grade

ROLE_FILE = "roles/team-manager.md"
ROLE_MODEL = parse_frontmatter_model(ROLE_FILE)

EVAL_PROMPT = """\
You are the Team Manager. Read your role definition carefully and apply it.

## Your Role Definition
{role_content}

## Situation

You have just received the following message from a team member:

{message}

Based on your role definition, output your exact next action:
- If delegating a task: output the task-assignment message(s) you would send (using the defined schema).
- If escalating to the user: output the message you would send the user.
- If shutting down: state that all work is complete and confirm to the user.

Be specific. Output ONLY your response — no preamble.
"""


def build_scenario(name, description, message, rubric):
    return {
        "name": name,
        "description": description,
        "mock_context": f"Inbound message:\n{message}",
        "message": message,
        "rubric": rubric,
    }


SCENARIOS = [
    build_scenario(
        name="triage_has_next_issue_delegates_plan",
        description="triage-report with next_issue → delegate assess-and-plan task",
        message="""\
type: triage-report
next_issue:
  id: PROJ-201
  title: Add user profile editing
  summary: Users need to edit their name, email, and avatar from the profile page.""",
        rubric=[
            "delegates tasks/plan.md (assess and plan) for issue PROJ-201",
            "task-assignment includes issue_id PROJ-201",
            "does NOT skip planning and jump directly to implementation",
        ],
    ),
    build_scenario(
        name="triage_null_issues_remain_escalates_to_user",
        description="triage-report null + blocked issues remain → escalate to user, do not delegate",
        message="""\
type: triage-report
next_issue: null

Context: 3 non-Done issues remain, all blocked:
- PROJ-301: awaiting product decision on pricing tiers
- PROJ-302: depends on PROJ-301 (not Done)
- PROJ-303: awaiting external API credentials from vendor""",
        rubric=[
            "does NOT delegate any implementation, test, or planning task",
            "informs the user that all remaining issues are blocked",
            "lists the blocked issues and their specific blockers",
            "waits for user direction rather than taking unilateral action",
        ],
    ),
    build_scenario(
        name="triage_null_no_issues_shutdown",
        description="triage-report null + no non-Done issues → confirm completion and shut down",
        message="""\
type: triage-report
next_issue: null

Context: All issues in the project are now Done. There are no remaining non-Done issues.""",
        rubric=[
            "does NOT delegate any further task",
            "confirms to the user that all project work is complete",
            "does not re-triage or start on imaginary work",
        ],
    ),
    build_scenario(
        name="plan_report_code_delegates_implementation",
        description="plan-report code → delegate code task",
        message="""\
type: plan-report
issue_id: PROJ-401
next_task: code
branch: feature/PROJ-401-payment-webhooks
worktree: /Users/dev/worktrees/feature/PROJ-401-payment-webhooks
plan: |
  1. Add WebhookEvent model
  2. Create POST /webhooks/stripe endpoint
  3. Validate Stripe signature header
  4. Process payment.succeeded and payment.failed events
  5. Add integration tests""",
        rubric=[
            "delegates tasks/code.md to a team member",
            "task-assignment includes branch, worktree, and plan",
        ],
    ),
    build_scenario(
        name="plan_report_test_delegates_test",
        description="plan-report test → delegate test task directly",
        message="""\
type: plan-report
issue_id: PROJ-404
next_task: test
pr_url: https://github.com/org/repo/pull/112""",
        rubric=[
            "delegates tasks/test.md to a team member",
            "task-assignment includes issue_id PROJ-404 and pr_url",
            "does NOT delegate an implementation task before testing",
        ],
    ),
    build_scenario(
        name="task_complete_delegates_test",
        description="task-complete → delegate test task with issue_id and pr_url",
        message="""\
type: task-complete
task: tasks/code.md
issue_id: PROJ-501
pr_url: https://github.com/org/repo/pull/120
summary: Implemented Stripe webhook handling with signature validation and idempotency.""",
        rubric=[
            "delegates tasks/test.md to a team member",
            "task-assignment includes issue_id PROJ-501 and pr_url https://github.com/org/repo/pull/120",
            "does NOT merge the PR or mark the issue Done at this stage",
        ],
    ),
    build_scenario(
        name="test_report_fail_re_implements_with_findings",
        description="test-report fail → re-delegate implementation with findings on same branch",
        message="""\
type: test-report
issue_id: PROJ-601
pr_url: https://github.com/org/repo/pull/130
outcome: fail
findings:
  - description: "Webhook endpoint returns 200 on invalid signature — should return 401"
    severity: critical
  - description: "Duplicate webhook events not deduplicated — payment processed twice"
    severity: critical""",
        rubric=[
            "re-delegates tasks/code.md to fix the findings",
            "task-assignment includes the test findings so the implementer knows what to fix",
            "task-assignment includes pr_url so the implementer works on the same branch",
            "does NOT route to demo-review after a failed test",
        ],
    ),
    build_scenario(
        name="test_report_pass_delegates_demo_review",
        description="test-report pass → delegate demo-review",
        message="""\
type: test-report
issue_id: PROJ-701
pr_url: https://github.com/org/repo/pull/140
outcome: pass
findings: []""",
        rubric=[
            "delegates tasks/demo-review.md to a team member",
            "task-assignment includes issue_id PROJ-701 and pr_url",
            "does NOT merge the PR (demo review must happen before merge)",
        ],
    ),
    build_scenario(
        name="demo_review_approved_re_triages",
        description="demo-review-report approved → re-triage for the next issue",
        message="""\
type: demo-review-report
issue_id: PROJ-801
outcome: approved
user_feedback: "Perfect, this is exactly what we needed."

Note: The demo reviewer has already merged the PR and marked the issue Done.""",
        rubric=[
            "re-delegates issue triage (tasks/issue-triage.md)",
            "does NOT skip triage and start on a specific next issue without re-triaging first",
        ],
    ),
    build_scenario(
        name="demo_review_redirect_handles_feedback_and_re_triages",
        description="demo-review-report redirect → act on feedback, do not merge, re-triage",
        message="""\
type: demo-review-report
issue_id: PROJ-901
outcome: redirect
user_feedback: "The export should include a summary row at the bottom showing totals. Please add before we ship."

Note: The demo reviewer has NOT merged the PR.""",
        rubric=[
            "does NOT merge the PR",
            "acts on the user feedback (notes the direction or updates the issue)",
            "re-triages to determine the next action (does not immediately assign implementation)",
        ],
    ),
    build_scenario(
        name="task_complete_with_followups_delegates_create_issue_and_test",
        description="task-complete with follow_up_issues → delegate create-issue AND test in parallel",
        message="""\
type: task-complete
task: tasks/code.md
issue_id: PROJ-1101
pr_url: https://github.com/org/repo/pull/155
summary: Implemented CSV export with streaming for large datasets.
follow_up_issues:
  - title: Add progress indicator for long-running exports
    description: src/export/csv.ts:42 — deferred UI feedback while export streams
  - title: Support XLSX format in addition to CSV
    description: src/export/csv.ts:10 — format abstraction not yet in scope""",
        rubric=[
            "delegates tasks/create-issue.md with source_issue_id PROJ-1101 and both follow-up issues",
            "delegates tasks/test.md with issue_id PROJ-1101 and pr_url",
            "delegates BOTH tasks (create-issue and test) — does not skip either",
            "does NOT wait for create-issue to complete before delegating test",
        ],
    ),
    build_scenario(
        name="create_issue_complete_no_further_routing",
        description="create-issue-complete → no further routing needed (test was already delegated in parallel)",
        message="""\
type: create-issue-complete
source_issue_id: PROJ-1101
created_issues:
  - id: PROJ-1201
    title: Add progress indicator for long-running exports
  - id: PROJ-1202
    title: Support XLSX format in addition to CSV""",
        rubric=[
            "does NOT delegate any new task",
            "does NOT re-delegate test (it was already delegated when task-complete arrived)",
            "does NOT re-triage or start on a different issue",
            "acknowledges the created issues without taking further action",
        ],
    ),
    build_scenario(
        name="demo_review_approved_with_followups_creates_issues_and_retriage",
        description="demo-review-report approved with follow_up_issues → create-issue and re-triage in parallel",
        message="""\
type: demo-review-report
issue_id: PROJ-801
outcome: approved
user_feedback: "Looks great! Could you also create a ticket to add keyboard shortcuts for the export actions?"
follow_up_issues:
  - title: Add keyboard shortcuts for export actions
    description: User requested during demo review — shortcuts not in original scope

Note: The demo reviewer has already merged the PR and marked the issue Done.""",
        rubric=[
            "delegates tasks/create-issue.md with the follow-up issue",
            "re-delegates issue triage (tasks/issue-triage.md)",
            "delegates BOTH tasks (create-issue and triage) — does not skip either",
            "does NOT wait for create-issue to complete before re-triaging",
        ],
    ),
    build_scenario(
        name="blocked_report_escalates_product_decision_to_user",
        description="blocked report requiring product decision → escalate to user, do not resolve unilaterally",
        message="""\
type: blocked
issue_id: PROJ-1001
what_is_blocked: Cannot implement notification preferences screen — no spec for which notification types to offer.
what_was_tried: Checked README, issue comments, and all project documentation. No notification types defined anywhere.
decision_needed: What notification types should users be able to toggle? (e.g. email, SMS, push, in-app)""",
        rubric=[
            "escalates the blocker to the user with the specific decision needed",
            "does NOT resolve the blocker by guessing or making the product decision unilaterally",
            "does NOT delegate any further work on PROJ-1001 until the user responds",
        ],
    ),
]


SPAWN_MODEL_PROMPT = """\
You are the Team Manager. Read your role definition carefully and apply it.

## Your Role Definition
{role_content}

## Task File Contents
You have read the following task file from disk:

{task_file_content}

## Situation

You have just received the following message from a team member:

{message}

You are about to spawn a team member and delegate this task to them.

1. Which task file would you assign?
2. What model would you specify when spawning the team member, and how did you determine it?
3. What subagent_type would you pass to the Agent tool, and why?

Be specific. Output ONLY your response — no preamble.
"""


def build_spawn_model_scenario(name, description, task_file, message, rubric):
    task_file_content = load_task(task_file)
    return {
        "name": name,
        "description": description,
        "mock_context": f"Task file ({task_file}):\n{task_file_content}\n\nInbound message:\n{message}",
        "message": message,
        "task_file": task_file,
        "task_file_content": task_file_content,
        "rubric": rubric,
    }


SPAWN_MODEL_SCENARIOS = [
    build_spawn_model_scenario(
        name="spawn_model_lightweight_task_uses_sonnet",
        description="After a triage report, manager reads tasks/plan.md frontmatter and spawns with claude-sonnet-4-6",
        task_file="tasks/plan.md",
        message="""\
type: triage-report
next_issue:
  id: PROJ-201
  title: Add user profile editing
  summary: Users need to edit their name, email, and avatar from the profile page.""",
        rubric=[
            "assigns tasks/plan.md for the planning task",
            "specifies claude-sonnet-4-6 as the model for the spawned teammate",
            "states or implies the model was read from the task file's YAML frontmatter",
        ],
    ),
    build_spawn_model_scenario(
        name="spawn_model_heavy_task_uses_opus",
        description="After a plan-report routing to code, manager reads tasks/code.md frontmatter and spawns with claude-opus-4-7",
        task_file="tasks/code.md",
        message="""\
type: plan-report
issue_id: PROJ-401
next_task: code
branch: feature/PROJ-401-payment-webhooks
worktree: /Users/dev/worktrees/feature/PROJ-401-payment-webhooks
plan: |
  1. Add WebhookEvent model
  2. Create POST /webhooks/stripe endpoint
  3. Validate Stripe signature header""",
        rubric=[
            "assigns tasks/code.md for the implementation task",
            "specifies claude-opus-4-7 as the model for the spawned teammate",
            "states or implies the model was read from the task file's YAML frontmatter",
        ],
    ),
    build_spawn_model_scenario(
        name="spawn_uses_general_purpose_subagent_type",
        description="When spawning a team member, manager must use subagent_type general-purpose, not team-member",
        task_file="tasks/issue-triage.md",
        message="""\
type: triage-report
next_issue:
  id: PROJ-101
  title: Fix login redirect bug
  summary: Users are not redirected after successful login.""",
        rubric=[
            "uses subagent_type 'general-purpose' when spawning the team member",
            "does NOT use subagent_type 'team-member' or any other non-standard value",
        ],
    ),
]


@pytest.mark.parametrize("scenario", SPAWN_MODEL_SCENARIOS, ids=[s["name"] for s in SPAWN_MODEL_SCENARIOS])
def test_manager_spawn_model_scenario(client, scenario):
    role_content = load_task(ROLE_FILE)
    prompt = SPAWN_MODEL_PROMPT.format(
        role_content=role_content,
        task_file_content=scenario["task_file_content"],
        message=scenario["message"],
    )
    response = client.chat.completions.create(
        model=ROLE_MODEL,
        messages=[{"role": "user", "content": prompt}],
        temperature=0,
        max_tokens=512,
    )
    agent_output = response.choices[0].message.content
    result = grade(client, scenario, agent_output, role_content)
    assert result.passed, "\n".join(result.failure_reasons)


@pytest.mark.parametrize("scenario", SCENARIOS, ids=[s["name"] for s in SCENARIOS])
def test_manager_routing_scenario(client, scenario):
    role_content = load_task(ROLE_FILE)
    prompt = EVAL_PROMPT.format(
        role_content=role_content,
        message=scenario["message"],
    )
    response = client.chat.completions.create(
        model=ROLE_MODEL,
        messages=[{"role": "user", "content": prompt}],
        temperature=0,
        max_tokens=768,
    )
    agent_output = response.choices[0].message.content
    result = grade(client, scenario, agent_output, role_content)
    assert result.passed, "\n".join(result.failure_reasons)
