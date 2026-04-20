"""
LLM-as-judge evals for the Issue Triage task.

Each scenario simulates a PM system state and verifies that the triage agent
produces the correct triage-report. Requires OPENROUTER_API_KEY.
"""
import pytest

from conftest import load_task
from judge import grade

TASK_FILE = "tasks/issue-triage.md"

EVAL_PROMPT = """\
You are a team member executing a task. Read the task definition carefully and follow it.

## Task Definition
{task_content}

## Simulated Environment

The following data represents what you would receive from calling the PM system tools. \
Treat this as the actual result of your tool calls — do not request additional information.

{mock_context}

Produce the complete output report as defined in the task. Output ONLY the report — no preamble, no explanation.
"""

SCENARIOS = [
    {
        "name": "all_issues_done",
        "description": "All issues in the project are marked Done — no work remains",
        "mock_context": """\
PM system query for non-Done issues returned 0 results.
All issues in the project have status "Done".""",
        "rubric": [
            "report type is 'triage-report'",
            "next_issue is null (no issue is selected for work)",
        ],
    },
    {
        "name": "all_issues_blocked",
        "description": "Non-Done issues exist but all are externally blocked",
        "mock_context": """\
PM system returned 3 non-Done issues:

- PROJ-101 "Add payment gateway" — Status: In Progress
  Dependencies: PROJ-98 "Auth system" — Status: In Progress (NOT Done)
  Blocker: dependency not Done

- PROJ-102 "User notifications" — Status: Todo
  Dependencies: PROJ-101 — Status: In Progress (NOT Done)
  Blocker: dependency not Done

- PROJ-103 "Admin dashboard" — Status: Todo
  Dependencies: none
  Blocker: unresolved architectural decision about multi-tenant database schema — no decision recorded in project docs""",
        "rubric": [
            "report type is 'triage-report'",
            "next_issue is null (all issues are blocked)",
            "does not classify any issue as Ready",
        ],
    },
    {
        "name": "one_ready_several_blocked",
        "description": "One ready issue should be selected; blocked issues should be excluded",
        "mock_context": """\
PM system returned 3 non-Done issues:

- PROJ-201 "Add CSV export" — Status: Todo — Priority: Medium
  Dependencies: none
  No unresolved decisions — READY

- PROJ-202 "Real-time sync" — Status: Todo — Priority: High
  Dependencies: PROJ-201 — Status: Todo (NOT Done)
  Blocker: depends on PROJ-201 which is not Done

- PROJ-203 "API rate limiting" — Status: Todo — Priority: Low
  Dependencies: none
  Blocker: unresolved product decision — rate limit thresholds not decided; no documentation found""",
        "rubric": [
            "report type is 'triage-report'",
            "next_issue is PROJ-201 (the only ready issue)",
            "PROJ-202 and PROJ-203 are not selected as next_issue",
        ],
    },
    {
        "name": "priority_ordering",
        "description": "Multiple ready issues — highest priority must be selected",
        "mock_context": """\
PM system returned 3 non-Done issues, all with no dependencies and no unresolved decisions (all Ready):

- PROJ-301 "Fix login redirect bug" — Priority: Urgent — Created: 2026-04-01
- PROJ-302 "Add dark mode" — Priority: Medium — Created: 2026-03-15
- PROJ-303 "Refactor auth module" — Priority: High — Created: 2026-03-20

Priority ranking (highest first): Urgent > High > Medium""",
        "rubric": [
            "report type is 'triage-report'",
            "next_issue is PROJ-301 (Urgent priority, highest in the list)",
            "does not select PROJ-302 or PROJ-303 as next_issue",
        ],
    },
    {
        "name": "unresolved_dependency_blocks",
        "description": "Issue with an unresolved dependency (dep not Done) must be Blocked",
        "mock_context": """\
PM system returned 1 non-Done issue:

- PROJ-401 "Checkout flow" — Status: Todo — Priority: High
  Dependencies: PROJ-400 "Payment gateway integration" — Status: In Progress (NOT Done)

PROJ-401 cannot start until PROJ-400 reaches Done.""",
        "rubric": [
            "report type is 'triage-report'",
            "next_issue is null (PROJ-401 is blocked by its dependency)",
            "PROJ-401 is classified as Blocked, not Ready",
        ],
    },
    {
        "name": "implementation_difficulty_is_not_a_blocker",
        "description": "Hard issue with no external blockers must be classified Ready, not Blocked",
        "mock_context": """\
PM system returned 1 non-Done issue:

- PROJ-501 "Implement ML-based product recommendations" — Status: Todo — Priority: High
  Dependencies: none
  No unresolved product or architectural decisions recorded.
  Note in issue description: "This is technically complex — team has no ML experience. \
Significant research and uncertainty expected."

No external dependencies or pending decisions exist for this issue.""",
        "rubric": [
            "report type is 'triage-report'",
            "next_issue is PROJ-501 (implementation difficulty alone is NOT a blocker)",
            "issue is classified as Ready, not Blocked",
        ],
    },
]


@pytest.mark.parametrize("scenario", SCENARIOS, ids=[s["name"] for s in SCENARIOS])
def test_triage_scenario(client, scenario):
    task_content = load_task(TASK_FILE)
    prompt = EVAL_PROMPT.format(
        task_content=task_content,
        mock_context=scenario["mock_context"],
    )
    response = client.chat.completions.create(
        model="anthropic/claude-sonnet-4-6",
        messages=[{"role": "user", "content": prompt}],
        temperature=0,
        max_tokens=512,
    )
    agent_output = response.choices[0].message.content
    result = grade(client, scenario, agent_output, task_content)
    assert result.passed, "\n".join(result.failure_reasons)
