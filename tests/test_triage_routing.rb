# frozen_string_literal: true
#
# LLM-as-judge evals for the Issue Triage task — Phase 2 (state assessment
# and routing).
#
# Covers every row in the routing decision table in tasks/issue-triage.md.
# Each scenario short-circuits Phase 1 by stating in the mock_context that the
# issue has already been picked as the highest-ranked Ready candidate; the
# rubric checks that Phase 2 produces the correct next_task and surrounding
# fields.
#
# Requires OPENROUTER_API_KEY.

require 'minitest/autorun'
require_relative 'eval_helper'
require_relative 'judge'

class TriageRoutingScenarioTest < Minitest::Test
  TASK_FILE = 'tasks/issue-triage.md'
  TASK_MODEL = EvalHelper.parse_frontmatter_model(TASK_FILE)

  EVAL_PROMPT = <<~PROMPT
    You are a teammate executing the Issue Triage task. Read the task definition carefully.

    ## Task Definition
    %<task_content>s

    ## Simulated Environment

    Assume Phase 1 has already run: the listed issue is the highest-ranked Ready candidate. The following data represents what you would receive from calling the PM system and git tools during Phase 2. Treat this as the actual result of your tool calls — do not request additional information.

    %<mock_context>s

    ## Instructions

    Determine the correct routing by working through Phase 2 of the task definition.

    - Skip Phase 2 steps that require real tools (marking the issue In Progress). Use only the information already in the Simulated Environment.
    - Extract `issue_title` and `issue_description` from the Simulated Environment when the route is `code`, `test`, or `demo-review`.
    - Populate `findings` only when there is a specific reason (test-failure findings, demo-review redirect feedback, staleness, merge conflicts, CI failure context, or unresolved review thread bodies). Omit `findings` entirely for a fresh start with no prior history.
    - `considered`, `exclusion_checked`, and `dependencies_checked` may be set to minimal placeholder arrays for the picked issue — these are validated separately in test_triage.rb.

    Output ONLY a single fenced ```json code block — no prose, analysis, or explanation before or after it.
  PROMPT

  SCENARIOS = [
    {
      name: 'approved_merged_nothing_to_do',
      description: 'Row 1: demo-review-complete approved + PR merged → no next_task',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-100 "Add user profile page"
        Status: Done
        Last updated: 2026-04-15 10:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/42 (2026-04-14 09:00 UTC)
        - type: test-complete, outcome: pass, findings: [], pr_url: https://github.com/org/repo/pull/42 (2026-04-14 14:00 UTC)
        - type: demo-review-complete, outcome: approved, user_feedback: "Perfect.", pr_url: https://github.com/org/repo/pull/42 (2026-04-15 09:00 UTC)

        Git state: branch feature/PROJ-100-user-profile exists. PR #42: MERGED.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "the report indicates no actionable work for this issue: either next_issue is null OR next_task is omitted/absent (the issue is Done and the agent should mark it Done then advance)",
        'report does NOT route this issue to test, demo-review, or code',
      ],
    },
    {
      name: 'demo_redirect_no_newer_implementation',
      description: 'Row 2: demo-review-complete redirect + no newer task-complete → implement',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-101 "Add dark mode toggle"
        Status: In Progress
        Last updated: 2026-04-18 08:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/55 (2026-04-16 10:00 UTC)
        - type: test-complete, outcome: pass, findings: [], pr_url: https://github.com/org/repo/pull/55 (2026-04-16 15:00 UTC)
        - type: demo-review-complete, outcome: redirect, pr_url: https://github.com/org/repo/pull/55, user_feedback: "The toggle should remember the user's preference across sessions. Currently resets on page refresh." (2026-04-17 11:00 UTC)

        There is NO task-complete comment newer than the demo-review-complete.

        Git state: branch feature/PROJ-101-dark-mode exists. PR #55: OPEN. CI: green.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'findings includes the user_feedback from the demo-review-complete comment',
        'does NOT route to test or demo-review',
      ],
    },
    {
      name: 'demo_redirect_with_newer_task_complete',
      description: 'Row 3: demo-review-complete redirect + newer task-complete → test',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-102 "Add CSV export"
        Status: In Progress
        Last updated: 2026-04-18 08:00 UTC

        PM issue comments (most recent of each type):
        - type: demo-review-complete, outcome: redirect, pr_url: https://github.com/org/repo/pull/60, user_feedback: "Include column headers in the CSV output." (2026-04-16 14:00 UTC)
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/60 (2026-04-18 09:00 UTC)  ← NEWER than demo-review-complete

        Git state: branch feature/PROJ-102-csv-export exists. PR #60: OPEN. CI: green.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'test'",
        'does NOT route to implement or demo-review',
      ],
    },
    {
      name: 'test_passed_not_stale_route_to_demo_review',
      description: 'Row 4: test-complete pass + not stale + PR open CI green → demo-review',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-103 "Add password reset flow"
        Status: In Progress
        Last updated: 2026-04-14 09:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/71 (2026-04-15 10:00 UTC)
        - type: test-complete, outcome: pass, findings: [], pr_url: https://github.com/org/repo/pull/71 (2026-04-16 14:00 UTC)

        Stale check: Issue last updated 2026-04-14 09:00 UTC. test-complete posted 2026-04-16 14:00 UTC.
        The issue was NOT updated after the test — NOT stale.

        Git state: branch feature/PROJ-103-password-reset exists. PR #71: OPEN. CI: green.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'demo-review'",
        'does NOT route to implement or test',
      ],
    },
    {
      name: 'test_passed_but_stale',
      description: 'Row 5: test-complete pass but issue updated after test → implement (stale)',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-104 "Search autocomplete"
        Status: In Progress
        Last updated: 2026-04-18 11:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/80 (2026-04-16 09:00 UTC)
        - type: test-complete, outcome: pass, findings: [], pr_url: https://github.com/org/repo/pull/80 (2026-04-16 15:00 UTC)

        Stale check: Issue last updated 2026-04-18 11:00 UTC. test-complete posted 2026-04-16 15:00 UTC.
        The acceptance criteria appear to have been edited after the test was posted — implementation is STALE.

        Git state: branch feature/PROJ-104-search-autocomplete exists. PR #80: OPEN. CI: green.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'report notes the stale condition (issue was updated after the test passed)',
        'does NOT route to demo-review',
      ],
    },
    {
      name: 'test_failed_route_to_implement_with_findings',
      description: 'Row 6: test-complete fail → implement with test findings',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-105 "Add two-factor authentication"
        Status: In Progress
        Last updated: 2026-04-15 10:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/85 (2026-04-16 11:00 UTC)
        - type: test-complete, outcome: fail, pr_url: https://github.com/org/repo/pull/85, findings: [
            {"description": "SMS code not sent when phone number includes country code (+1)", "severity": "critical"},
            {"description": "Rate limiting not applied — unlimited codes can be requested", "severity": "critical"}
          ] (2026-04-17 14:00 UTC)

        Git state: branch feature/PROJ-105-2fa exists. PR #85: OPEN. CI: green.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'the findings field mentions BOTH test failures: the SMS country code issue AND the rate limiting issue (any format — string, list, or structured — is acceptable as long as both are present)',
        'does NOT route to test or demo-review',
      ],
    },
    {
      name: 'task_complete_pr_open_ci_green',
      description: 'Row 7: task-complete + PR open + CI green → test',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-106 "Add invoice download"
        Status: In Progress
        Last updated: 2026-04-15 09:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/90 (2026-04-16 10:00 UTC)
        No test-complete comment. No demo-review-complete comment.

        Git state: branch feature/PROJ-106-invoice-download exists. PR #90: OPEN. CI: all checks green.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'test'",
        'does NOT route to implement or demo-review',
      ],
    },
    {
      name: 'task_complete_ci_failing',
      description: 'Row 8: task-complete + PR open + CI failing → re-implement',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-107 "Webhook retry logic"
        Status: In Progress
        Last updated: 2026-04-15 09:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/95 (2026-04-16 10:00 UTC)
        No test-complete comment. No demo-review-complete comment.

        Git state: branch feature/PROJ-107-webhook-retry exists. PR #95: OPEN.
        CI: FAILING — 3 test failures in webhook_retry_test.go (TestRetryExponentialBackoff, TestRetryMaxAttempts, TestRetryDeadLetter)
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'findings field includes context about the CI failure (e.g. names of failing tests or a description of what is broken)',
      ],
    },
    {
      name: 'no_task_complete_branch_exists_no_pr',
      description: 'Row 9: no task-complete + branch exists + no PR → implement, reuse branch',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-108 "Add OAuth login"
        Status: In Progress
        Last updated: 2026-04-15 09:00 UTC
        Acceptance criteria:
          1. User can sign in with Google OAuth from the login page
          2. New users are auto-provisioned on first OAuth sign-in
          3. Existing users with a matching email are linked to their OAuth identity
          4. Session persists across browser restarts via secure cookie

        PM issue comments: NONE (no task-complete, test-complete, or demo-review-complete)

        Git state:
        - Branch feature/PROJ-108-oauth-login exists locally (3 commits, partially implemented)
        - No open PR for this issue found via: gh pr list --search "PROJ-108" --state open (0 results)
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'branch field references the existing branch feature/PROJ-108-oauth-login (reuses it, does not create a new one)',
      ],
    },
    {
      name: 'demo_redirect_newer_task_complete_unresolved_threads',
      description: 'Row 3a: demo-review redirect + newer task-complete + unresolved threads → code',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-112 "Add CSV export"
        Status: In Progress
        Last updated: 2026-04-18 08:00 UTC

        PM issue comments (most recent of each type):
        - type: demo-review-complete, outcome: redirect, pr_url: https://github.com/org/repo/pull/60, user_feedback: "Include column headers in the CSV output." (2026-04-16 14:00 UTC)
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/60 (2026-04-18 09:00 UTC)  ← NEWER than demo-review-complete

        Git state: branch feature/PROJ-112-csv-export exists. PR #60: OPEN. CI: green.
        Unresolved review threads (2):
        1. "You're not closing the file handle after writing — this will leak on large exports."
        2. "Missing test for empty dataset case."
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'findings includes the unresolved review thread bodies (file handle leak and/or missing test)',
        'does NOT route to test or demo-review',
      ],
    },
    {
      name: 'test_passed_not_stale_unresolved_threads',
      description: 'Row 4a: test-complete pass + not stale + unresolved review threads → code',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-113 "Add password reset flow"
        Status: In Progress
        Last updated: 2026-04-14 09:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/71 (2026-04-15 10:00 UTC)
        - type: test-complete, outcome: pass, findings: [], pr_url: https://github.com/org/repo/pull/71 (2026-04-16 14:00 UTC)

        Stale check: Issue last updated 2026-04-14 09:00 UTC. test-complete posted 2026-04-16 14:00 UTC.
        The issue was NOT updated after the test — NOT stale.

        Git state: branch feature/PROJ-113-password-reset exists. PR #71: OPEN. CI: green.
        Unresolved review threads (1):
        1. "The reset token expiry is hardcoded to 1 hour — should be configurable via env var."
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'findings includes the unresolved review thread body about the hardcoded expiry',
        'does NOT route to demo-review',
      ],
    },
    {
      name: 'task_complete_pr_open_ci_green_unresolved_threads',
      description: 'Row 7a: task-complete + PR open + CI green + unresolved review threads → code',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-114 "Add invoice download"
        Status: In Progress
        Last updated: 2026-04-15 09:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/90 (2026-04-16 10:00 UTC)
        No test-complete comment. No demo-review-complete comment.

        Git state: branch feature/PROJ-114-invoice-download exists. PR #90: OPEN. CI: all checks green.
        Unresolved review threads (2):
        1. "PDF generation is synchronous — this will block the request thread for large invoices. Move to a background job."
        2. "No access control check — any authenticated user can download any invoice by ID."
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'findings includes the unresolved review thread bodies (background job and/or access control)',
        'does NOT route to test or demo-review',
      ],
    },
    {
      name: 'task_complete_pr_has_merge_conflicts',
      description: 'task-complete + PR open + merge conflicts → code to rebase and resolve conflicts',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-115 "Add audit log export"
        Status: In Progress
        Last updated: 2026-04-15 09:00 UTC

        PM issue comments (most recent of each type):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/92 (2026-04-16 10:00 UTC)
        No test-complete comment. No demo-review-complete comment.

        Git state: branch feature/PROJ-115-audit-log-export exists. PR #92: OPEN.
        PR mergeability check: mergeable=CONFLICTING, mergeStateStatus=DIRTY — the branch has merge conflicts with main.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'findings field mentions merge conflicts or the need to rebase',
        'does NOT route to test or demo-review while conflicts exist',
      ],
    },
    {
      name: 'multi_pr_approved_but_another_open',
      description: 'demo-review-complete approved for PR #42, but a second task-complete references a different open PR #50 with CI green → route to test or demo-review for PR #50',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-116 "Implement multi-step onboarding"
        Status: In Progress
        Last updated: 2026-04-20 10:00 UTC

        PM issue comments (all comments, chronological):
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/42 (2026-04-17 09:00 UTC)
        - type: test-complete, outcome: pass, findings: [], pr_url: https://github.com/org/repo/pull/42 (2026-04-17 14:00 UTC)
        - type: demo-review-complete, outcome: approved, user_feedback: "Step 1 looks great.", pr_url: https://github.com/org/repo/pull/42 (2026-04-18 09:00 UTC)
        - type: task-complete, task: tasks/code.md, pr_url: https://github.com/org/repo/pull/50 (2026-04-19 11:00 UTC)

        Associated PRs (from all task-complete comments):
        - https://github.com/org/repo/pull/42 → MERGED
        - https://github.com/org/repo/pull/50 → OPEN

        Git state: PR #42: MERGED. PR #50: OPEN. CI for PR #50: all checks green. No unresolved review threads on PR #50.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'test' or 'demo-review' (NOT 'nothing to do' or absent/null)",
        'the report references PR #50 (https://github.com/org/repo/pull/50) — the still-open PR',
        'does NOT declare the issue Done or report that there is nothing to do',
      ],
    },
    {
      name: 'small_issue_routes_to_code',
      description: 'Small focused issue → triage-report with next_task: code (splitting is the code task’s job, not triage)',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-201 "Add 'forgot password' link to login page"
        Status: Todo
        Last updated: 2026-04-20 09:00 UTC
        Acceptance criteria:
          1. Login page has a 'Forgot password?' link below the password field
          2. Link navigates to /auth/forgot-password

        PM issue comments: NONE

        Git state: No branch, no PR.
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        'does NOT set next_task to create-issue (triage no longer makes split decisions — code does)',
      ],
    },
    {
      name: 'no_work_done_start_fresh',
      description: 'Row 10: no task-complete + no branch + no PR → fresh implementation',
      mock_context: <<~CTX.chomp,
        Issue: PROJ-109 "Tighten footer spacing on the marketing landing page"
        Status: Todo
        Last updated: 2026-04-10 09:00 UTC
        Acceptance criteria:
          1. Reduce vertical padding above the footer on /landing from 96px to 64px (single CSS change in src/styles/landing.css)

        PM issue comments: NONE (no task-complete, test-complete, or demo-review-complete)

        Git state:
        - No branch for PROJ-109 found locally
        - No open PR found via: gh pr list --search "PROJ-109" --state open (0 results)
      CTX
      rubric: [
        "report type is 'triage-report'",
        "next_task is 'code'",
        "branch field is non-empty and contains a branch name that includes the issue ID (case-insensitive: 'PROJ-109' or 'proj-109')",
      ],
    },
  ].freeze

  SCENARIOS.each do |scenario|
    define_method("test_triage_routing_#{scenario[:name]}") do
      skip 'OPENROUTER_API_KEY not set — skipping LLM eval' unless EvalHelper.openrouter_available?

      task_content = EvalHelper.load_task(TASK_FILE)
      prompt = format(EVAL_PROMPT, task_content: task_content, mock_context: scenario[:mock_context])
      result = Judge.grade_with_retries(scenario: scenario, task_content: task_content) do
        EvalHelper.openrouter_chat(
          model: TASK_MODEL,
          user: prompt,
          temperature: 0,
          max_tokens: 2048,
        )
      end
      assert result.passed, result.failure_reasons.join("\n")
    end
  end
end
