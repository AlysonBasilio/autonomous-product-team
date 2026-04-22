"""
LLM-as-judge evals for the Discovery task.

Each scenario simulates a discovery context and verifies that the discovery
agent produces correct follow-up issues and a valid discovery-complete report.

Requires OPENROUTER_API_KEY.
"""
import pytest

from conftest import load_task, parse_frontmatter_model
from judge import grade

TASK_FILE = "tasks/discovery.md"
TASK_MODEL = parse_frontmatter_model(TASK_FILE)

EVAL_PROMPT = """\
You are a team member executing a task. Read the task definition carefully and follow it.

## Task Definition
{task_content}

## Simulated Environment

The following data represents what you would receive from calling the PM system and codebase tools. \
Treat this as the actual result of your tool calls — do not request additional information.

{mock_context}

Produce the complete output report as defined in the task. Output ONLY the report — no preamble, no explanation.
"""

SCENARIOS = [
    {
        "name": "basic_discovery_creates_issues",
        "description": "Given a vague feature request, agent creates appropriately scoped follow-up issues",
        "mock_context": """\
PM system issue:
- ID: PROJ-50
- Title: "We should have a notification system"
- Description: "Users have asked for notifications so they know when important things happen in their account. \
We need to figure out what this looks like and break it into concrete work."
- Status: Backlog
- Comments: none

Codebase research results:
- No existing notification code found in the codebase
- The app has a User model with email and phone fields (src/models/user.py)
- There is an existing event system that logs user actions (src/events/logger.py)
- The frontend uses React with a top-level App component (src/frontend/App.tsx)
- No WebSocket infrastructure exists currently

Existing non-Done issues in PM system:
- PROJ-45 "Add user preferences page" — Status: Todo — no dependencies
- PROJ-48 "Improve email delivery reliability" — Status: In Progress — no dependencies

PM system created the following issues when requested:
- PROJ-51 "Define notification types and delivery channels" — Status: Backlog, Priority: No priority
- PROJ-52 "Build notification service backend" — Status: Backlog, Priority: No priority
- PROJ-53 "Add in-app notification UI" — Status: Backlog, Priority: No priority""",
        "rubric": [
            "report type is 'discovery-complete'",
            "at least two follow-up issues are created (the discovery breaks the vague request into concrete work)",
            "follow-up issue descriptions include background referencing the discovery issue PROJ-50",
            "follow-up issues are scoped to specific pieces of work, not just restating the original request",
        ],
    },
    {
        "name": "discovery_with_existing_codebase_context",
        "description": "Agent reads relevant files and uses that context in issue descriptions",
        "mock_context": """\
PM system issue:
- ID: PROJ-60
- Title: "Support bulk CSV import for products"
- Description: "Merchants want to upload a CSV file to create or update many products at once \
instead of entering them one by one."
- Status: Backlog
- Comments: none

Codebase research results:
- Products are managed via src/api/products.py with a POST /products endpoint for single creation
- Product model is defined in src/models/product.py with fields: id, name, sku, price, description, merchant_id
- There is an existing file upload utility at src/utils/upload.py that handles S3 uploads
- The API uses FastAPI with Pydantic validation (src/api/main.py)
- Background job processing uses Celery with Redis broker (src/jobs/worker.py)
- No CSV parsing library is currently in requirements.txt

Existing non-Done issues in PM system:
- PROJ-55 "Add product image gallery" — Status: Todo — no dependencies
- PROJ-58 "Rate limit API endpoints" — Status: In Progress — no dependencies

PM system created the following issues when requested:
- PROJ-61 "Add CSV parsing and validation for product import" — Status: Backlog, Priority: No priority
- PROJ-62 "Create background job for bulk product import processing" — Status: Backlog, Priority: No priority
- PROJ-63 "Add CSV import API endpoint and UI upload flow" — Status: Backlog, Priority: No priority""",
        "rubric": [
            "report type is 'discovery-complete'",
            "follow-up issue descriptions reference specific codebase findings (e.g. existing Product model, FastAPI, Celery, or file paths)",
            "the agent uses codebase context to inform the work breakdown (not just generic implementation steps)",
            "created issues mention relevant existing infrastructure (e.g. Celery for background jobs, existing upload utility, or Pydantic validation)",
        ],
    },
    {
        "name": "discovery_produces_discovery_complete_report",
        "description": "Output schema is correct: type, issue_id, summary, created_issues with id and title",
        "mock_context": """\
PM system issue:
- ID: PROJ-70
- Title: "Investigate adding dark mode"
- Description: "Some users have requested dark mode support. We need to understand what this involves."
- Status: Backlog
- Comments: none

Codebase research results:
- Frontend uses Tailwind CSS (tailwind.config.js)
- No dark mode classes or theme switching logic exists
- Color values are hardcoded in several component files

Existing non-Done issues in PM system: none

PM system created the following issues when requested:
- PROJ-71 "Add Tailwind dark mode configuration and theme toggle component" — Status: Backlog, Priority: No priority
- PROJ-72 "Audit and update hardcoded colors to support dark mode" — Status: Backlog, Priority: No priority""",
        "rubric": [
            "report type field is exactly 'discovery-complete'",
            "issue_id field is present and equals PROJ-70",
            "summary field is present and is a single sentence describing the discovery",
            "created_issues field is a list with at least one entry, each having id and title fields",
        ],
    },
]


@pytest.mark.parametrize("scenario", SCENARIOS, ids=[s["name"] for s in SCENARIOS])
def test_discovery_scenario(client, scenario):
    task_content = load_task(TASK_FILE)
    prompt = EVAL_PROMPT.format(
        task_content=task_content,
        mock_context=scenario["mock_context"],
    )
    response = client.chat.completions.create(
        model=TASK_MODEL,
        messages=[{"role": "user", "content": prompt}],
        temperature=0,
        max_tokens=1024,
    )
    agent_output = response.choices[0].message.content
    result = grade(client, scenario, agent_output, task_content)
    assert result.passed, "\n".join(result.failure_reasons)
