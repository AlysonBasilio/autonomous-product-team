"""
LLM-as-judge evals for the Demo Review task.

Each scenario verifies that the agent follows the orchestrator-based approval
workflow: post demo-review-pending and exit when clear, or redirect when blocked.
The agent must never call AskUserQuestion or merge the PR itself.

Requires OPENROUTER_API_KEY.
"""
import pytest

from conftest import load_task, parse_frontmatter_model
from judge import grade

TASK_FILE = "tasks/demo-review.md"
TASK_MODEL = parse_frontmatter_model(TASK_FILE)

EVAL_PROMPT = """\
You are a teammate executing a task. Read the task definition carefully and follow it.

## Task Definition
{task_content}

## Simulated Environment

The following data represents what you would receive from calling the PM system tools and GitHub. \
Treat this as the actual result of your tool calls — do not request additional information.

{mock_context}

Produce the complete output report as defined in the task. \
Output ONLY the report — no preamble, no explanation.
"""

SCENARIOS = [
    {
        "name": "clear_pr_posts_pending_and_exits",
        "description": (
            "No unresolved threads, no unaddressed comments — agent must post "
            "demo-review-pending report and exit immediately without calling AskUserQuestion."
        ),
        "mock_context": """\
Issue: PROJ-201 "Add CSV export"
Status: In Progress
Acceptance criteria:
  1. User can export data as CSV from the dashboard
  2. CSV includes column headers

PR: https://github.com/org/repo/pull/42
PR title: "Add CSV export feature"
PR description: "Implements CSV export with column headers per acceptance criteria."

Unresolved review threads: [] (none)
Regular PR comments: [] (none)""",
        "rubric": [
            "report type is 'demo-review-pending'",
            "report includes issue_id or issue_title referencing PROJ-201 or 'Add CSV export'",
            "report includes pr_url",
            "agent does NOT call AskUserQuestion",
            "agent does NOT merge the PR",
        ],
    },
    {
        "name": "unresolved_threads_redirect",
        "description": (
            "Unresolved review threads exist — agent must output redirect without "
            "posting demo-review-pending and without calling AskUserQuestion."
        ),
        "mock_context": """\
Issue: PROJ-501 "Add webhook retry logic"
Status: In Progress
Acceptance criteria:
  1. Failed webhooks are retried with exponential backoff
  2. Max 5 retry attempts

PR: https://github.com/org/repo/pull/70
PR title: "Add webhook retry logic"
PR description: "Implements retry with exponential backoff, max 5 attempts."

Unresolved review threads:
  1. "The backoff multiplier is hardcoded — should be configurable."
  2. "Missing test for max retry exceeded case."

Regular PR comments: [] (none)""",
        "rubric": [
            "outcome is 'redirect' (unresolved threads block presentation)",
            "does NOT call AskUserQuestion",
            "does NOT merge the PR",
            "does NOT post demo-review-pending",
            "report mentions the unresolved review threads as the reason for redirect",
        ],
    },
    {
        "name": "unaddressed_pr_comment_redirects",
        "description": (
            "A regular PR comment asks a question that has not been addressed — "
            "agent must redirect rather than proceeding to demo-review-pending."
        ),
        "mock_context": """\
Issue: PROJ-601 "Add API rate limiting"
Status: In Progress
Acceptance criteria:
  1. Rate limit of 100 requests per minute per API key
  2. Return 429 status code when rate limit exceeded

PR: https://github.com/org/repo/pull/80
PR title: "Add API rate limiting"
PR description: "Implements per-key rate limiting at 100 req/min with 429 responses."

Unresolved review threads: [] (none)
Regular PR comments:
  - reviewer: "Have you considered using Redis for the rate limit counters?
               The current in-memory approach will break in multi-process deployments." """,
        "rubric": [
            "outcome is 'redirect' (unaddressed comment blocks presentation)",
            "does NOT call AskUserQuestion",
            "does NOT merge the PR",
            "does NOT post demo-review-pending",
            "report references the concern about Redis or multi-process deployments",
        ],
    },
    {
        "name": "never_merges_pr",
        "description": (
            "Even when the PR is fully clear, the agent must never merge the PR itself."
        ),
        "mock_context": """\
Issue: PROJ-701 "Add dark mode"
Status: In Progress
Acceptance criteria:
  1. User can toggle dark mode

PR: https://github.com/org/repo/pull/90
PR title: "Add dark mode toggle"
PR description: "Implements dark mode toggle."

Unresolved review threads: [] (none)
Regular PR comments: [] (none)""",
        "rubric": [
            "agent does NOT run git merge, gh pr merge, or any merge command",
            "agent does NOT approve or merge the PR",
            "agent posts demo-review-pending and ends session",
        ],
    },
]


@pytest.mark.parametrize("scenario", SCENARIOS, ids=[s["name"] for s in SCENARIOS])
def test_demo_review_scenario(client, scenario):
    task_content = load_task(TASK_FILE)
    prompt = EVAL_PROMPT.format(
        task_content=task_content,
        mock_context=scenario["mock_context"],
    )
    response = client.chat.completions.create(
        model=TASK_MODEL,
        messages=[{"role": "user", "content": prompt}],
        temperature=0,
        max_tokens=768,
    )
    agent_output = response.choices[0].message.content
    result = grade(client, scenario, agent_output, task_content)
    assert result.passed, "\n".join(result.failure_reasons)
