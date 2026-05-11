# frozen_string_literal: true
#
# LLM-as-judge evals for the Issue Triage task.
#
# Each scenario simulates a PM system state and verifies that the triage agent
# produces the correct triage-report. Requires OPENROUTER_API_KEY.

require 'minitest/autorun'
require_relative 'eval_helper'
require_relative 'judge'

class TriageScenarioTest < Minitest::Test
  TASK_FILE = 'tasks/issue-triage.md'
  TASK_MODEL = EvalHelper.parse_frontmatter_model(TASK_FILE)

  EVAL_PROMPT = <<~PROMPT
    You are a teammate executing a task. Read the task definition carefully and follow it.

    ## Task Definition
    %<task_content>s

    ## Simulated Environment

    The following data represents what you would receive from calling the PM system tools. Treat this as the actual result of your tool calls — do not request additional information.

    %<mock_context>s

    Produce the complete output report as defined in the task. Output ONLY the report — no preamble, no explanation.
  PROMPT

  SCENARIOS = [
    {
      name: 'all_issues_done',
      description: 'All issues in the project are marked Done — no work remains',
      mock_context: <<~CTX.chomp,
        PM system query for non-Done issues returned 0 results.
        All issues in the project have status "Done".
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is null (no issue is selected for work)',
      ],
    },
    {
      name: 'all_issues_blocked',
      description: 'Non-Done issues exist but all are externally blocked',
      mock_context: <<~CTX.chomp,
        PM system returned 3 non-Done issues:

        - PROJ-101 "Add payment gateway" — Status: In Progress
          Dependencies: PROJ-98 "Auth system" — Status: In Progress (NOT Done)
          Blocker: dependency not Done

        - PROJ-102 "User notifications" — Status: Todo
          Dependencies: PROJ-101 — Status: In Progress (NOT Done)
          Blocker: dependency not Done

        - PROJ-103 "Admin dashboard" — Status: Todo
          Dependencies: none
          Blocker: unresolved architectural decision about multi-tenant database schema — no decision recorded in project docs
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is null (all issues are blocked)',
        'does not classify any issue as Ready',
      ],
    },
    {
      name: 'one_ready_several_blocked',
      description: 'One ready issue should be selected; blocked issues should be excluded',
      mock_context: <<~CTX.chomp,
        PM system returned 3 non-Done issues:

        - PROJ-201 "Add CSV export" — Status: Todo — Priority: Medium
          Dependencies: none
          No unresolved decisions — READY

        - PROJ-202 "Real-time sync" — Status: Todo — Priority: High
          Dependencies: PROJ-201 — Status: Todo (NOT Done)
          Blocker: depends on PROJ-201 which is not Done

        - PROJ-203 "API rate limiting" — Status: Todo — Priority: Low
          Dependencies: none
          Blocker: unresolved product decision — rate limit thresholds not decided; no documentation found
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is PROJ-201 (the only ready issue)',
        'PROJ-202 and PROJ-203 are not selected as next_issue',
      ],
    },
    {
      name: 'priority_ordering',
      description: 'Multiple ready issues — highest priority must be selected',
      mock_context: <<~CTX.chomp,
        PM system returned 3 non-Done issues, all with no dependencies and no unresolved decisions (all Ready):

        - PROJ-301 "Fix login redirect bug" — Priority: Urgent — Created: 2026-04-01
        - PROJ-302 "Add dark mode" — Priority: Medium — Created: 2026-03-15
        - PROJ-303 "Refactor auth module" — Priority: High — Created: 2026-03-20

        Priority ranking (highest first): Urgent > High > Medium
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is PROJ-301 (Urgent priority, highest in the list)',
        'does not select PROJ-302 or PROJ-303 as next_issue',
      ],
    },
    {
      name: 'unresolved_dependency_blocks',
      description: 'Issue with an unresolved dependency (dep not Done) must be Blocked',
      mock_context: <<~CTX.chomp,
        PM system returned 1 non-Done issue:

        - PROJ-401 "Checkout flow" — Status: Todo — Priority: High
          Dependencies: PROJ-400 "Payment gateway integration" — Status: In Progress (NOT Done)

        PROJ-401 cannot start until PROJ-400 reaches Done.
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is null (PROJ-401 is blocked by its dependency)',
        'PROJ-401 is classified as Blocked, not Ready',
      ],
    },
    {
      name: 'pm_api_error_produces_task_failed',
      description: 'PM system returns an error — agent must report task-failed, not triage-report',
      mock_context: <<~CTX.chomp,
        Attempt to fetch non-Done issues from the PM system failed with error:
        "The query is too complex"

        No issue data was returned.
      CTX
      rubric: [
        "report type is 'task-failed' (not 'triage-report')",
        "task field is 'tasks/issue-triage.md'",
        'failure field describes the PM API error',
      ],
    },
    {
      name: 'explicit_body_reference_blocks',
      description: "Issue body contains 'Depends on #B' where B is not Done — A must be Blocked",
      mock_context: <<~CTX.chomp,
        PM system returned 2 non-Done issues:

        - PROJ-601 "Build onboarding flow" — Status: Todo — Priority: High
          Dependencies (PM system links): none
          Issue body: "This work depends on #602 being completed first. We need the user auth system before we can build onboarding."

        - PROJ-602 "Implement user auth system" — Status: Todo — Priority: High
          Dependencies (PM system links): none
          Issue body: "Set up authentication with OAuth2 and JWT tokens."

        PROJ-602 has no dependencies and no unresolved decisions.
        PROJ-601 has no formal PM-system dependency links, but its body text says "depends on #602".
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is PROJ-602 (PROJ-601 is blocked by its body reference to #602 which is not Done, so PROJ-602 is the only ready issue)',
        "PROJ-601 is NOT selected as next_issue (it is blocked because its body says 'depends on #602' and #602 is not Done)",
      ],
    },
    {
      name: 'semantic_dependency_blocks',
      description: "One issue describes running a capability another issue creates — the 'run' issue is Blocked, the 'create' issue is Ready",
      mock_context: <<~CTX.chomp,
        PM system returned 2 non-Done issues:

        - PROJ-701 "Run a discovery on claude code hooks" — Status: Todo — Priority: Medium
          Dependencies (PM system links): none
          Issue body: "Run a product discovery to explore how teams use claude code hooks. Interview users, gather data, and synthesize findings."

        - PROJ-702 "Create a discovery task type" — Status: Todo — Priority: Medium
          Dependencies (PM system links): none
          Issue body: "Add a new 'discovery' task type to our product development process. Define the template, inputs, outputs, and workflow for running discoveries."

        Neither issue has formal PM-system dependency links. No unresolved decisions exist.
        Note: PROJ-701 describes *running* a discovery, which requires the discovery task type that PROJ-702 would create. There are no explicit cross-references between them.
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is PROJ-702 (it creates the capability that PROJ-701 needs, making it the ready issue)',
        'PROJ-701 is NOT selected as next_issue (it semantically depends on the discovery task type that PROJ-702 will create)',
      ],
    },
    {
      name: 'dependency_only_visible_via_per_issue_lookup',
      description: "Listing endpoint hides relations — agent must do per-issue lookups to find the blocker",
      mock_context: <<~CTX.chomp,
        The PM system's list endpoint returned 3 non-Done issues with basic fields only.
        Dependency relations are NOT included in the listing — you must call the
        per-issue detail endpoint (one call per issue) to retrieve them.

        Listing result (basic fields only):
          - PROJ-801 "Account switcher UI for payor section" — Status: Todo — Priority: High — Created: 2026-04-10
          - PROJ-802 "Backend payor user-linking workflow"   — Status: In Progress — Priority: High — Created: 2026-04-08
          - PROJ-803 "Refactor settings page header"          — Status: Todo — Priority: Low  — Created: 2026-04-02

        Per-issue detail lookups (what you receive when you call the detail endpoint for each ID):
          - PROJ-801 detail → blocked_by: ["PROJ-802"]. Body: "Extend the account switcher to surface the payor section."
          - PROJ-802 detail → blocked_by: []. Body: "Implement the Temporal workflow that links payor users to businesses."
          - PROJ-803 detail → blocked_by: []. Body: "Tighten spacing on the settings page header."

        Important: an agent that skips per-issue detail lookups (e.g. only fetches the listing) will incorrectly classify PROJ-801 as Ready.
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is PROJ-803 (PROJ-801 is blocked by PROJ-802 via per-issue relation; PROJ-802 is itself In Progress so still not Done; only PROJ-803 is Ready)',
        'PROJ-801 is NOT selected as next_issue',
        "considered array includes all three issue IDs (PROJ-801, PROJ-802, PROJ-803) — the agent attests to having run per-issue lookups on each",
      ],
    },
    {
      name: 'zero_results_trigger_retry_not_emptiness',
      description: 'Initial listing returns 0 — agent must retry with a resolved project ID before concluding empty',
      mock_context: <<~CTX.chomp,
        First tool call:
          list_issues({ project: "identity-permissions-and-team-admin-828469115565", state: "non-done" })
          → []  (zero results)

        The project URL slug above is NOT the project's canonical ID. The PM system accepts the call but silently returns 0 results when the filter shape is wrong.

        After resolving the project's canonical ID via a project-lookup call, a second listing returned 3 non-Done issues:

          - PROJ-901 "Wire up SSO callback handler" — Status: Todo — Priority: High — Created: 2026-04-12
            Dependencies (per-issue lookup): none
            No unresolved decisions — READY

          - PROJ-902 "Add audit log retention policy" — Status: In Progress — Priority: Medium — Created: 2026-04-09
            Dependencies (per-issue lookup): none
            No unresolved decisions — READY

          - PROJ-903 "Rename internal team field"   — Status: Todo — Priority: Low — Created: 2026-04-01
            Dependencies (per-issue lookup): none
            No unresolved decisions — READY
      CTX
      rubric: [
        "report type is 'triage-report' (NOT 'task-failed' — the zero-result initial listing is not authoritative)",
        'next_issue is PROJ-901 (High priority, the highest-ranked Ready issue from the retry)',
        'considered array includes PROJ-901, PROJ-902, and PROJ-903',
      ],
    },
    {
      name: 'zero_results_persist_after_retries_produces_task_failed',
      description: 'Both initial and retry listings return 0 — agent must emit task-failed and quote the calls verbatim',
      mock_context: <<~CTX.chomp,
        First tool call:
          list_issues({ project: "identity-permissions-and-team-admin-828469115565", state: "non-done" })
          → []

        Second tool call (after resolving the canonical project ID):
          list_issues({ project: "8f3e1c92-4d20-4b88-9a55-0e1f4e7a2b91", state: "non-done" })
          → []

        Third tool call (Retry B — re-query without any status filter, per the task's zero-result protocol):
          list_issues({ project: "8f3e1c92-4d20-4b88-9a55-0e1f4e7a2b91" })
          → []

        Retry B also returned 0 issues — no issues exist in this project under any status filter.
      CTX
      rubric: [
        "report type is 'task-failed' (NOT 'triage-report')",
        "task field is 'tasks/issue-triage.md'",
        'failure field includes the exact tool name (list_issues) and the exact arguments passed on at least one retry attempt — not just a summary like "returned no issues"',
      ],
    },
    {
      name: 'implementation_difficulty_is_not_a_blocker',
      description: 'Hard issue with no external blockers must be classified Ready, not Blocked',
      mock_context: <<~CTX.chomp,
        PM system returned 1 non-Done issue:

        - PROJ-501 "Implement ML-based product recommendations" — Status: Todo — Priority: High
          Dependencies: none
          No unresolved product or architectural decisions recorded.
          Note in issue description: "This is technically complex — team has no ML experience. Significant research and uncertainty expected."

        No external dependencies or pending decisions exist for this issue.
      CTX
      rubric: [
        "report type is 'triage-report'",
        'next_issue is PROJ-501 (implementation difficulty alone is NOT a blocker)',
        'issue is classified as Ready, not Blocked',
      ],
    },
  ].freeze

  SCENARIOS.each do |scenario|
    define_method("test_triage_#{scenario[:name]}") do
      skip 'OPENROUTER_API_KEY not set — skipping LLM eval' unless EvalHelper.openrouter_available?

      task_content = EvalHelper.load_task(TASK_FILE)
      prompt = format(EVAL_PROMPT, task_content: task_content, mock_context: scenario[:mock_context])
      agent_output = EvalHelper.openrouter_chat(
        model: TASK_MODEL,
        user: prompt,
        temperature: 0,
        max_tokens: 512,
      )
      result = Judge.grade(scenario: scenario, agent_output: agent_output, task_content: task_content)
      assert result.passed, result.failure_reasons.join("\n")
    end
  end
end
