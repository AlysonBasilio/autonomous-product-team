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
        name="plan_report_implement_backend_delegates_backend",
        description="plan-report implement-backend → delegate backend implementation only",
        message="""\
type: plan-report
issue_id: PROJ-401
next_task: implement-backend
branch: feature/PROJ-401-payment-webhooks
worktree: /Users/dev/worktrees/feature/PROJ-401-payment-webhooks
plan: |
  1. Add WebhookEvent model
  2. Create POST /webhooks/stripe endpoint
  3. Validate Stripe signature header
  4. Process payment.succeeded and payment.failed events
  5. Add integration tests""",
        rubric=[
            "delegates tasks/implement-backend.md to a team member",
            "task-assignment includes branch, worktree, and plan",
            "does NOT also delegate implement-frontend simultaneously",
        ],
    ),
    build_scenario(
        name="plan_report_implement_frontend_delegates_frontend",
        description="plan-report implement-frontend → delegate frontend implementation only",
        message="""\
type: plan-report
issue_id: PROJ-402
next_task: implement-frontend
branch: feature/PROJ-402-onboarding-wizard
worktree: /Users/dev/worktrees/feature/PROJ-402-onboarding-wizard
plan: |
  1. Create OnboardingWizard component (3-step)
  2. Add step routing and progress indicator
  3. Wire to existing /api/onboarding endpoint
  4. Add unit tests for each step""",
        rubric=[
            "delegates tasks/implement-frontend.md to a team member",
            "task-assignment includes branch, worktree, and plan",
            "does NOT also delegate implement-backend",
        ],
    ),
    build_scenario(
        name="plan_report_implement_both_delegates_in_parallel",
        description="plan-report implement-both → delegate backend AND frontend in parallel",
        message="""\
type: plan-report
issue_id: PROJ-403
next_task: implement-both
branch: feature/PROJ-403-notifications
worktree: /Users/dev/worktrees/feature/PROJ-403-notifications
plan: |
  Backend:
  1. Add Notification model and migrations
  2. Create GET /notifications and PATCH /notifications/:id endpoints
  3. Add background job for email delivery
  Frontend:
  1. Add notification bell to nav
  2. Build notification dropdown component
  3. Integrate with backend API""",
        rubric=[
            "delegates BOTH tasks/implement-backend.md AND tasks/implement-frontend.md",
            "both tasks are delegated in parallel (not one after the other)",
            "both task-assignments reference the same branch and worktree",
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
task: tasks/implement-backend.md
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
            "re-delegates an implementation task (implement-backend or implement-frontend)",
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
