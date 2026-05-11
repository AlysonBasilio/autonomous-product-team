# frozen_string_literal: true
#
# Static structural checks — no API calls, runs in milliseconds.
#
# Verifies that task definition files are internally consistent:
# - All referenced task files exist
# - The plan routing table covers all required decision branches
# - Input/output fields chain correctly between tasks
# - Every task defines an output report schema
# - Every task specifies a valid model in its frontmatter

require 'minitest/autorun'
require 'json'
require 'set'
require_relative 'eval_helper'

REPO_ROOT = EvalHelper::REPO_ROOT

VALID_MODELS = [
  'anthropic/claude-opus-4.7',
  'anthropic/claude-sonnet-4-6',
  'anthropic/claude-haiku-4.5',
  'openai/gpt-5.4',
  'openai/gpt-5.4-mini',
  'google/gemini-3.1-pro-preview',
  'google/gemini-3.1-flash-lite-preview',
  'deepseek/deepseek-v4-pro',
].freeze

TASK_FILES = Dir[File.join(REPO_ROOT, 'tasks/*.md')].sort.map do |abs|
  abs.sub("#{REPO_ROOT}/", '')
end.freeze

def load_file(path)
  File.read(File.join(REPO_ROOT, path))
end

# Extract a single YAML frontmatter field value from a Markdown file.
def parse_frontmatter_field(path, field)
  content = load_file(path)
  return nil unless content.start_with?('---')

  end_idx = content.index("\n---", 3)
  return nil unless end_idx

  frontmatter = content[3...end_idx]
  match = frontmatter.match(/^#{Regexp.escape(field)}:\s*(.+)/)
  match && match[1].strip
end

def parse_frontmatter_model(path)
  parse_frontmatter_field(path, 'model')
end

class TestTaskFileExistence < Minitest::Test
  # Referenced task files must exist on disk.

  def test_code_exists
    assert File.exist?(File.join(REPO_ROOT, 'tasks/code.md'))
  end

  def test_status_correction_exists
    assert File.exist?(File.join(REPO_ROOT, 'tasks/status-correction.md'))
  end
end

class TestPlanRoutingTable < Minitest::Test
  # Plan routing table must cover every important decision branch.
  # Removing or renaming a branch should cause one of these tests to fail.

  def test_routing_covers_demo_review_approved
    assert_match(/demo-review-complete.*approved/i, load_file('tasks/plan.md'),
                 'Plan routing table must handle demo-review-complete approved')
  end

  def test_routing_covers_demo_review_redirect
    assert_match(/demo-review-complete.*redirect/i, load_file('tasks/plan.md'),
                 'Plan routing table must handle demo-review-complete redirect')
  end

  def test_routing_covers_test_pass
    assert_match(/test-complete.*pass/i, load_file('tasks/plan.md'),
                 'Plan routing table must handle test-complete pass')
  end

  def test_routing_covers_test_fail
    assert_match(/test-complete.*fail/i, load_file('tasks/plan.md'),
                 'Plan routing table must handle test-complete fail')
  end

  def test_routing_covers_stale_implementation
    assert_includes load_file('tasks/plan.md').downcase, 'stale',
                    'Plan routing table must handle the stale-implementation case ' \
                    '(issue updated after test passed)'
  end

  def test_routing_covers_task_complete_with_open_pr
    assert_match(/task-complete.*exists/i, load_file('tasks/plan.md'),
                 'Plan routing table must handle task-complete with open PR')
  end

  def test_routing_covers_task_complete_with_broken_ci
    assert_match(/CI failing|CI green/i, load_file('tasks/plan.md'),
                 'Plan routing table must distinguish CI green vs failing states')
  end

  def test_routing_covers_no_work_done
    assert_match(/No.*task-complete|no.*task-complete/, load_file('tasks/plan.md'),
                 'Plan routing table must handle the case where no work has been done yet')
  end

  def test_routing_covers_branch_exists_no_pr
    assert_match(/[Bb]ranch exists/, load_file('tasks/plan.md'),
                 'Plan routing table must handle branch-exists-but-no-PR state')
  end

  def test_plan_defines_next_task_values
    content = load_file('tasks/plan.md')
    %w[code test demo-review].each do |value|
      assert_includes content, value, "plan.md must document next_task value: #{value}"
    end
  end

  def test_routing_covers_merge_conflicts
    assert_match(/merge.conflict/i, load_file('tasks/plan.md'),
                 'Plan routing table must handle the case where a PR has merge conflicts')
  end

  def test_plan_checks_mergeability
    assert_includes load_file('tasks/plan.md').downcase, 'mergeable',
                    'plan.md must instruct the agent to check PR mergeability ' \
                    '(e.g. via gh pr view --json mergeable)'
  end
end

class TestMergeConflictHandling < Minitest::Test
  # Merge conflict detection and resolution must be covered in code.md.

  def test_code_instructs_conflict_resolution_on_rebase
    assert_match(/conflict/i, load_file('tasks/code.md'),
                 'code.md must instruct the agent to resolve merge conflicts during rebase')
  end

  def test_code_instructs_task_failed_on_unresolvable_conflicts
    content = load_file('tasks/code.md')
    assert_includes content, 'task-failed',
                    'code.md must instruct the agent to report task-failed when conflicts cannot be resolved'
    assert_match(/conflict/i, content,
                 'code.md must mention conflicts in the context of task-failed reporting')
  end
end

class TestInputOutputChain < Minitest::Test
  # Fields produced by one task must be consumed by the appropriate downstream task.
  # A missing field in the producer or consumer breaks the hand-off.

  def test_plan_outputs_branch_consumed_by_implement
    assert_includes load_file('tasks/plan.md'), 'branch'
    assert_includes load_file('tasks/code.md'), 'branch'
  end

  def test_plan_outputs_findings_consumed_by_implement
    assert_includes load_file('tasks/plan.md'), 'findings'
    assert_includes load_file('tasks/code.md'), 'findings'
  end

  def test_implement_outputs_pr_url_consumed_by_test
    assert_includes load_file('tasks/code.md'), 'pr_url'
    assert_includes load_file('tasks/test.md'), 'pr_url'
  end

  def test_test_outputs_issue_id_consumed_by_demo_review
    assert_includes load_file('tasks/test.md'), 'issue_id'
    assert_includes load_file('tasks/demo-review.md'), 'issue_id'
  end

  def test_demo_review_outputs_user_feedback_consumed_by_implement
    assert_includes load_file('tasks/demo-review.md'), 'user_feedback'
    assert_includes load_file('tasks/code.md'), 'user_feedback'
  end
end

class TestReportSchemas < Minitest::Test
  # Each task must define its complete output report schema.

  def test_triage_defines_report_schema
    content = load_file('tasks/issue-triage.md')
    assert_includes content, 'triage-report'
    assert_includes content, 'next_issue'
  end

  def test_plan_defines_report_schema
    content = load_file('tasks/plan.md')
    assert_includes content, 'plan-report'
    assert_includes content, 'next_task'
    assert_includes content, 'issue_id'
  end

  def test_code_defines_task_complete
    content = load_file('tasks/code.md')
    assert_includes content, 'task-complete'
    assert_includes content, 'pr_url'
    assert_includes content, 'summary'
  end

  def test_code_defines_task_failed
    content = load_file('tasks/code.md')
    assert_includes content, 'task-failed'
    assert_includes content, 'failure'
  end

  def test_test_defines_test_report
    content = load_file('tasks/test.md')
    assert_includes content, 'test-report'
    assert_includes content, 'outcome'
    assert_includes content, 'findings'
  end

  def test_triage_defines_task_failed
    content = load_file('tasks/issue-triage.md')
    assert_includes content, 'task-failed'
    assert_includes content, 'failure'
  end

  def test_triage_excludes_deleted_issues
    content = load_file('tasks/issue-triage.md')
    assert_match(/deleted|trashed/i, content,
                 'tasks/issue-triage.md must instruct the agent to skip deleted/trashed issues')
    assert_match(/considered/i, content,
                 'tasks/issue-triage.md must clarify that excluded issues do not enter `considered`')
  end

  def test_demo_review_defines_pending_report
    assert_includes load_file('tasks/demo-review.md'), 'demo-review-pending'
  end

  def test_create_issue_supports_priority_field
    assert_includes load_file('tasks/create-issue.md'), 'priority',
                    'tasks/create-issue.md must support an optional priority field'
  end
end

class TestMultiPRHandling < Minitest::Test
  # Verify that multi-PR tracking is documented in plan.md and demo-review.md.

  def test_plan_mentions_multi_pr_handling
    assert_match(/all.*PR|associated PR|multi-PR/i, load_file('tasks/plan.md'),
                 "tasks/plan.md must mention multi-PR handling (e.g., 'all PRs', 'associated PRs', or 'multi-PR')")
  end

  def test_plan_mentions_all_prs_merged_or_closed
    assert_match(/all.*(?:PRs|associated).*(?:merged|closed)/i, load_file('tasks/plan.md'),
                 'tasks/plan.md routing table must require all associated PRs to be merged or closed')
  end

  def test_plan_handles_remaining_open_prs
    assert_match(/other.*PR.*open|remaining.*PR|associated PRs still open/i, load_file('tasks/plan.md'),
                 'tasks/plan.md routing table must handle the case where some associated PRs are still open ' \
                 '(multi-PR tracking moved from demo-review to plan.md)')
  end
end

class TestDemoReviewApprovalGate < Minitest::Test
  # demo-review.md must delegate approval to the orchestrator and never self-merge.

  def test_demo_review_prohibits_merge
    assert_match(/NEVER merge/, load_file('tasks/demo-review.md'),
                 'demo-review.md must explicitly prohibit the agent from merging the PR')
  end

  def test_demo_review_prohibits_ask_user_question
    assert_match(/NOT call.*AskUserQuestion|Do NOT call.*AskUserQuestion|NEVER.*AskUserQuestion/,
                 load_file('tasks/demo-review.md'),
                 'demo-review.md must prohibit AskUserQuestion — approval is handled by the orchestrator')
  end
end

class TestModelSpecification < Minitest::Test
  # Every task must specify a valid model in YAML frontmatter.

  def test_all_files_have_frontmatter_model
    TASK_FILES.each do |path|
      model = parse_frontmatter_model(path)
      refute_nil model, "#{path} is missing a 'model:' field in YAML frontmatter"
    end
  end

  def test_all_models_are_valid
    TASK_FILES.each do |path|
      model = parse_frontmatter_model(path)
      assert_includes VALID_MODELS, model,
                      "#{path} specifies unknown model '#{model}'; must be one of #{VALID_MODELS.sort}"
    end
  end
end

class TestSessionPersistence < Minitest::Test
  # Session persistence: Synthup credentials and project registry are submitted
  # via the web UI and persist under data/. The orchestrator must wait for both
  # before dispatching tasks.

  def test_server_exposes_global_config_endpoint
    content = load_file('orchestrator/server.rb')
    assert_includes content, '/api/config',
                    'orchestrator/server.rb must expose POST /api/config'
    %w[tenant api_key].each do |key|
      assert_includes content, key,
                      "orchestrator/server.rb must reference required config key '#{key}'"
    end
  end

  def test_server_exposes_project_endpoints
    content = load_file('orchestrator/server.rb')
    %w[/api/projects /activate].each do |route|
      assert_includes content, route, "orchestrator/server.rb must expose #{route}"
    end
  end

  def test_config_persists_via_storage
    content = load_file('orchestrator/config.rb')
    assert_includes content, 'save_synthup_credentials',
                    'Config.save_synthup_credentials must persist Synthup tenant + api_key'
    assert_includes content, 'set_active_project_id',
                    'Config.set_active_project_id must persist the active project'
  end

  def test_run_waits_for_setup_before_dispatch
    content = load_file('orchestrator/run.rb')
    assert_includes content, 'wait_for_setup',
                    'orchestrator/run.rb must gate task dispatch on wait_for_setup (creds + active project)'
    assert_includes content, 'synthup_configured?',
                    'orchestrator/run.rb must check synthup_configured? before dispatching'
  end
end

class TestQABlockedDelegation < Minitest::Test
  # When the QA agent cannot run the app itself, it must hand the test to
  # the user via a `test-blocked` report. The orchestrator routes this to
  # the wait-approval gate — there is no more pre-flight doc scan.

  def test_test_defines_test_blocked_report
    content = load_file('tasks/test.md')
    assert_includes content, 'test-blocked',
                    'tasks/test.md must define the test-blocked report type'
    assert_includes content, 'issue_id',
                    'tasks/test.md test-blocked report must include issue_id'
    assert_includes content, 'pr_url',
                    'tasks/test.md test-blocked report must include pr_url'
    assert_includes content, 'summary',
                    'tasks/test.md test-blocked report must include a summary ' \
                    "(matches router.rb's report['summary'] read)"
  end

  def test_test_attempts_before_delegating
    content = load_file('tasks/test.md').downcase
    assert(content.include?('try to') || content.include?('attempt'),
           'tasks/test.md must instruct the agent to try running the app itself ' \
           'before handing off to the user')
  end
end

class TestSplitReport < Minitest::Test
  # Split-report schema must be fully defined in plan.md and create-issue.md.

  def test_plan_defines_split_report_type
    assert_includes load_file('tasks/plan.md'), 'split-report',
                    'plan.md must define the split-report message type'
  end

  def test_plan_defines_scope_assessment
    assert_match(/scope|too big|single PR/i, load_file('tasks/plan.md'),
                 'plan.md must include a scope assessment step explaining when an issue is too big for a single PR')
  end

  def test_plan_split_report_has_required_fields
    content = load_file('tasks/plan.md')
    %w[source_issue_id reason issues depends_on].each do |field|
      assert_includes content, field, "plan.md split-report schema is missing field: #{field}"
    end
  end

  def test_create_issue_accepts_and_echoes_context
    assert_includes load_file('tasks/create-issue.md'), 'context',
                    'create-issue.md must accept and echo the optional context field'
  end
end

# Mirrored from orchestrator/task_runner.rb — keep in sync.
KNOWN_REPORT_TYPES = %w[
  triage-report plan-report task-complete split-report test-report
  demo-review-pending demo-review-report discovery-complete
  create-issue-complete status-correction-report
  test-blocked task-failed blocked
].to_set

# Report types that agents author in task specs. demo-review-report is
# constructed by orchestrator/run.rb after UI approval, never by an agent —
# so it isn't expected to appear as a fenced JSON example in any task spec.
EXPECTED_AGENT_REPORT_TYPES = KNOWN_REPORT_TYPES - ['demo-review-report'].to_set

# Types not authored in any task spec today (router-only handlers).
TYPES_NOT_IN_TASK_SPECS = ['blocked'].to_set

# Return every fenced ```json block in content that successfully JSON-parses.
def fenced_json_blocks(content)
  blocks = []
  content.scan(/^[ \t]*```json\n(.*?)\n[ \t]*```/m) do |captures|
    begin
      blocks << JSON.parse(captures[0])
    rescue JSON::ParserError
      next
    end
  end
  blocks
end

class TestReportFormatIsJson < Minitest::Test
  # Each agent-authored report block in tasks/*.md must be fenced ```json and
  # parse as valid JSON. Regression guard against drift back to YAML-ish format.
  #
  # Fixtures use angle-bracket placeholders like "<issue ID>" — JSON parsing
  # treats those as plain strings, so the example payloads must already be
  # syntactically valid JSON.

  def test_every_known_report_type_appears_in_a_task_spec
    types_seen = Set.new
    TASK_FILES.each do |task_path|
      fenced_json_blocks(load_file(task_path)).each do |block|
        types_seen << block['type'] if block.is_a?(Hash) && block.key?('type')
      end
    end

    expected = EXPECTED_AGENT_REPORT_TYPES - TYPES_NOT_IN_TASK_SPECS
    missing = expected - types_seen
    assert missing.empty?,
           "Report types missing a fenced ```json example in tasks/*.md: #{missing.to_a.sort}. " \
           'Each agent-emitted report type must have a JSON example so the ' \
           "orchestrator's extract_report can match it."
  end

  def test_every_fenced_json_block_in_task_specs_parses
    TASK_FILES.each do |task_path|
      content = load_file(task_path)
      content.scan(/^[ \t]*```json\n(.*?)\n[ \t]*```/m) do |captures|
        block = captures[0]
        JSON.parse(block)
      rescue JSON::ParserError => e
        raise Minitest::Assertion,
              "#{task_path} contains a ```json block that does not parse: #{e.message}\nBlock:\n#{block}"
      end
    end
  end

  def test_no_yaml_style_report_blocks_remain
    # Catch the old YAML-ish ` ```\ntype: foo\n... ` shape that the
    # orchestrator's extract_report cannot match (this is the bug that
    # caused issue-triage to time out at 30 minutes).
    type_alternation = EXPECTED_AGENT_REPORT_TYPES.map { |t| Regexp.escape(t) }.join('|')
    bad_pattern = /```(?!json\n)[a-z]*\n\s*type:\s*(#{type_alternation})\b/
    TASK_FILES.each do |task_path|
      content = load_file(task_path)
      match = bad_pattern.match(content)
      assert_nil match,
                 "#{task_path} still has a YAML-style report block (`type: #{match && match[1]}` " \
                 "inside a non-json fence). The orchestrator's extract_report only matches " \
                 'fenced ```json blocks — convert this to JSON.'
    end
  end
end

require_relative '../orchestrator/template'
require_relative '../orchestrator/router'

class TestTaskInputsFrontmatter < Minitest::Test
  # Every tasks/*.md must declare an `inputs:` frontmatter block listing
  # the keys the orchestrator may pass in. The block makes the dispatch
  # contract between router and task explicit and statically checkable.

  def test_every_task_declares_inputs
    TASK_FILES.each do |path|
      content = load_file(path)
      assert content.start_with?('---'),
             "#{path} is missing YAML frontmatter"
      end_idx = content.index("\n---", 3)
      refute_nil end_idx, "#{path} has unterminated frontmatter"
      frontmatter = content[3...end_idx]
      assert_match(/^inputs:/, frontmatter,
                   "#{path} must declare an `inputs:` block in frontmatter (use empty " \
                   '`required: []`/`optional: []` arrays when there are no inputs)')
    end
  end

  def test_inputs_block_parses_to_arrays
    TASK_FILES.each do |path|
      spec = Template.parse(File.join(REPO_ROOT, path))
      assert_kind_of Array, spec.required, "#{path}: inputs.required must be an array"
      assert_kind_of Array, spec.optional, "#{path}: inputs.optional must be an array"
      (spec.required + spec.optional).each do |k|
        assert_match(/\A[a-z][a-z0-9_]*\z/, k,
                     "#{path}: input name '#{k}' must be snake_case")
      end
    end
  end

  def test_no_undeclared_placeholders
    # Every {{ key }} reference in a task body must be declared in inputs
    # (required or optional) or be an implicit key like project_url.
    TASK_FILES.each do |path|
      spec = Template.parse(File.join(REPO_ROOT, path))
      declared = (spec.required + spec.optional + Template::IMPLICIT_KEYS).to_set
      placeholders = spec.body.scan(/\{\{\s*(\w+|\.)\s*\}\}/).map(&:first)
      sections    = spec.body.scan(/\{\{#\s*(\w+)\s*\}\}/).map(&:first)
      (placeholders + sections).uniq.each do |k|
        next if k == '.'
        assert declared.include?(k),
               "#{path}: {{#{k}}} is not in inputs (#{declared.to_a.sort.join(', ')})"
      end
    end
  end
end

class TestRouterSuppliesRequiredInputs < Minitest::Test
  # For every router branch that dispatches a task, confirm the supplied
  # context includes every key the task declares as required. This catches
  # dispatch bugs at static-test time — if a future change adds a required
  # input but the router still calls the task without it, this fails.

  # Sample reports exercising each branch in Router.route. Use the same field
  # shapes the producer tasks actually emit — in particular triage-report's
  # `next_issue` is a `{id, title, summary}` object, not a bare ID string —
  # so that the rendered prompt picks up dispatch-time type bugs.
  ROUTER_FIXTURES = [
    { 'type' => 'triage-report',
      'next_issue' => { 'id' => 'ENG-1', 'title' => 't', 'summary' => 's' },
      'issue_type' => 'implementation' },
    { 'type' => 'triage-report',
      'next_issue' => { 'id' => 'ENG-1', 'title' => 't', 'summary' => 's' },
      'issue_type' => 'discovery' },
    { 'type' => 'plan-report', 'next_task' => 'code',
      'issue_id' => 'ENG-1', 'branch' => 'b', 'plan' => 'p' },
    { 'type' => 'plan-report', 'next_task' => 'test',
      'issue_id' => 'ENG-1', 'pr_url' => 'u' },
    { 'type' => 'plan-report', 'next_task' => 'demo-review',
      'issue_id' => 'ENG-1', 'pr_url' => 'u' },
    { 'type' => 'split-report',
      'source_issue_id' => 'ENG-1', 'issues' => [{ 'title' => 't' }] },
    { 'type' => 'task-complete',
      'issue_id' => 'ENG-1', 'pr_url' => 'u' },
    { 'type' => 'task-complete',
      'issue_id' => 'ENG-1', 'pr_url' => 'u',
      'follow_up_issues' => [{ 'title' => 't' }] },
    { 'type' => 'discovery-complete' },
    { 'type' => 'test-report', 'outcome' => 'pass',
      'issue_id' => 'ENG-1', 'pr_url' => 'u' },
    { 'type' => 'test-report', 'outcome' => 'fail',
      'issue_id' => 'ENG-1', 'pr_url' => 'u',
      'findings' => [{ 'description' => 'd', 'severity' => 'critical' }] },
    { 'type' => 'demo-review-report', 'outcome' => 'approved',
      'issue_id' => 'ENG-1', 'pr_url' => 'u' },
    { 'type' => 'demo-review-report', 'outcome' => 'redirect',
      'issue_id' => 'ENG-1', 'pr_url' => 'u', 'user_feedback' => 'f' }
  ].freeze

  def each_dispatched_task(action)
    case action[:type]
    when 'run-task'
      yield action[:task], action[:context] || {}
    when 'run-tasks-parallel'
      action[:tasks].each { |t| yield t[:task], t[:context] || {} }
    end
  end

  def test_router_branches_supply_required_inputs
    ROUTER_FIXTURES.each do |report|
      action = Router.route(report)
      each_dispatched_task(action) do |task, context|
        path = File.join(REPO_ROOT, 'tasks', task)
        spec = Template.parse(path)
        ctx_keys = context.keys.map(&:to_s)
        missing = spec.required - ctx_keys
        assert missing.empty?,
               "Router.route(#{report['type']}, outcome=#{report['outcome'].inspect}) " \
               "→ #{task}: missing required input(s) #{missing.inspect} " \
               "(context supplied: #{ctx_keys.sort.inspect})"
      end
    end
  end

  def test_router_dispatched_tasks_render_without_errors
    # End-to-end: take each fixture report, route it, and actually render
    # the resulting task with the supplied context. Catches type bugs the
    # required-keys check misses (e.g. passing a Hash where a scalar is
    # expected).
    ROUTER_FIXTURES.each do |report|
      action = Router.route(report)
      each_dispatched_task(action) do |task, context|
        path = File.join(REPO_ROOT, 'tasks', task)
        full_ctx = { 'project_url' => 'https://example/p/x' }.merge(
          context.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
        )
        Template.render(path, full_ctx)
      rescue Template::Error => e
        flunk "Router.route(#{report['type']}, outcome=#{report['outcome'].inspect}) " \
              "→ #{task}: render failed with #{e.class.name.split('::').last}: #{e.message}"
      end
    end
  end

  def test_router_does_not_pass_unknown_keys
    # Every key the router supplies must be declared in inputs (required
    # or optional). project_url is added by dispatch_task, not the router,
    # so it doesn't appear in router branches.
    ROUTER_FIXTURES.each do |report|
      action = Router.route(report)
      each_dispatched_task(action) do |task, context|
        path = File.join(REPO_ROOT, 'tasks', task)
        spec = Template.parse(path)
        declared = (spec.required + spec.optional).to_set
        ctx_keys = context.keys.map(&:to_s)
        unknown = ctx_keys - declared.to_a
        assert unknown.empty?,
               "Router.route(#{report['type']}) → #{task} passes undeclared key(s) " \
               "#{unknown.inspect}; add them to inputs.optional or stop passing them"
      end
    end
  end
end
