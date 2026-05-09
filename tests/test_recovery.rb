#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Tests for the recovery-exhausted escalation path: reminders fire at the
# expected thresholds, the report carries enough context for the user, and the
# router routes it to escalate.
#
# Run: ruby tests/test_recovery.rb

require 'minitest/autorun'

orchestrator_dir = File.expand_path('../orchestrator', __dir__)
$LOAD_PATH.unshift(orchestrator_dir)
require 'task_runner'
require 'router'

class NextRecoveryThresholdTest < Minitest::Test
  def setup
    @timeout = 1800
  end

  def call(elapsed, fired = [])
    TaskRunner.next_recovery_threshold(elapsed: elapsed, timeout: @timeout, fired: fired)
  end

  def test_no_threshold_before_50_percent
    assert_nil call(0)
    assert_nil call(100)
    assert_nil call((@timeout * 0.5).to_i - 1)
  end

  def test_first_threshold_fires_at_50_percent
    assert_equal 0.5, call(@timeout * 0.5)
  end

  def test_second_threshold_fires_at_75_percent_after_first
    assert_equal 0.75, call(@timeout * 0.75, [0.5])
  end

  def test_third_threshold_fires_at_90_percent_after_first_two
    assert_equal 0.9, call(@timeout * 0.9, [0.5, 0.75])
  end

  def test_returns_first_unfired_eligible_threshold
    # At 90% elapsed with nothing fired, we should still get 0.5 first
    # (one threshold per poll iteration; the loop calls us again next poll).
    assert_equal 0.5, call(@timeout * 0.9, [])
  end

  def test_returns_nil_when_all_fired
    assert_nil call(@timeout * 0.95, [0.5, 0.75, 0.9])
  end
end

class RecoveryExhaustedReportTest < Minitest::Test
  def test_report_shape
    report = TaskRunner.recovery_exhausted_report(
      session_id:     'sess-abc',
      reason:         'Session timed out after 1800s without producing a JSON report',
      elapsed_s:      1800,
      reminders_sent: 3,
      last_content:   'agent was responding to PR feedback'
    )
    assert_equal 'recovery-exhausted', report['type']
    assert_includes report['details'], 'session_id: sess-abc'
    assert_includes report['details'], 'elapsed: 1800s'
    assert_includes report['details'], 'reminders_sent: 3'
    assert_includes report['details'], 'agent was responding to PR feedback'
  end

  def test_truncates_long_content_to_tail
    long = 'a' * 2000 + 'TAIL_MARKER'
    report = TaskRunner.recovery_exhausted_report(
      session_id: 'x', reason: 'r', elapsed_s: 1, reminders_sent: 0, last_content: long
    )
    assert_includes report['details'], 'TAIL_MARKER'
    refute_includes report['details'], ('a' * 1500) # full content not present
  end

  def test_handles_missing_last_content
    report = TaskRunner.recovery_exhausted_report(
      session_id: 'x', reason: 'r', elapsed_s: 1, reminders_sent: 0, last_content: nil
    )
    assert_equal 'recovery-exhausted', report['type']
    refute_includes report['details'], 'Last observed content'
  end
end

class RecoveryRouterTest < Minitest::Test
  def test_recovery_exhausted_routes_to_escalate
    report = { 'type' => 'recovery-exhausted', 'details' => 'something happened' }
    action = Router.route(report)
    assert_equal 'escalate', action[:type]
    assert_equal 'recovery-exhausted', action[:reason]
    assert_equal 'something happened', action[:details]
  end

  def test_recovery_exhausted_falls_back_to_full_report_when_no_details
    report = { 'type' => 'recovery-exhausted' }
    action = Router.route(report)
    assert_equal 'escalate', action[:type]
    assert_includes action[:details], 'recovery-exhausted'
  end

  def test_task_failed_still_escalates_separately
    # Genuine session failures (not missed reports) keep their own reason so
    # they aren't masked as "we lost the JSON".
    report = { 'type' => 'task-failed', 'details' => 'real error' }
    action = Router.route(report)
    assert_equal 'escalate', action[:type]
    assert_equal 'task-failed', action[:reason]
  end
end

class SendRecoveryReminderTest < Minitest::Test
  def setup
    @original_send_message = Synthup.method(:send_message)
  end

  def teardown
    Synthup.define_singleton_method(:send_message, @original_send_message)
  end

  def test_returns_true_on_success_and_calls_synthup
    captured = []
    Synthup.define_singleton_method(:send_message) do |session_id, prompt:, model: nil|
      captured << { session_id: session_id, prompt: prompt }
      nil
    end
    result = TaskRunner.send_recovery_reminder('sess-1', 'sess-1', 900, 0.5, nil)
    assert_equal true, result
    assert_equal 1, captured.length
    assert_equal 'sess-1', captured[0][:session_id]
    assert_includes captured[0][:prompt], 'final JSON report'
  end

  def test_returns_false_on_synthup_error
    Synthup.define_singleton_method(:send_message) do |*_args, **_kwargs|
      raise Synthup::Error.new(500, 'boom')
    end
    result = TaskRunner.send_recovery_reminder('sess-1', 'sess-1', 900, 0.5, nil)
    assert_equal false, result
  end

  def test_returns_false_on_transient_network_error
    Synthup.define_singleton_method(:send_message) do |*_args, **_kwargs|
      raise Net::OpenTimeout, 'connect timed out'
    end
    require 'net/http'
    result = TaskRunner.send_recovery_reminder('sess-1', 'sess-1', 900, 0.5, nil)
    assert_equal false, result
  end
end

class KnownReportTypesTest < Minitest::Test
  def test_recovery_exhausted_is_known
    assert_includes TaskRunner::KNOWN_REPORT_TYPES, 'recovery-exhausted'
  end
end

# Regression: a recovery nudge (role=user) embeds example JSON of every known
# report type. If the poller treats that nudge as the agent's reply, it pulls
# the placeholder example out and dispatches on it — landing on demo-review
# with `<PR URL>` and `<issue ID>` strings (real incident, ENG-1886 session).
# Reports must only come from role=assistant messages.
class PollRoleFilterTest < Minitest::Test
  def setup
    @original_get = Synthup.method(:get_last_message)
    @original_send = Synthup.method(:send_message)
    Synthup.define_singleton_method(:send_message) { |*_a, **_k| nil }
  end

  def teardown
    Synthup.define_singleton_method(:get_last_message, @original_get)
    Synthup.define_singleton_method(:send_message, @original_send)
  end

  def stub_sequence(messages)
    queue = messages.dup
    Synthup.define_singleton_method(:get_last_message) do |_sid|
      queue.length > 1 ? queue.shift : queue.first
    end
  end

  def example_test_blocked_content
    <<~MD
      Please send your final JSON report. Expected shape:

      ```json
      {
        "type": "test-blocked",
        "issue_id": "<issue ID>",
        "pr_url": "<PR URL>",
        "summary": "<one sentence: what you tried and what blocked you>"
      }
      ```
    MD
  end

  def test_user_message_with_example_json_is_not_extracted
    stub_sequence([
      { 'role' => 'user', 'content' => example_test_blocked_content },
      { 'role' => 'assistant', 'content' => "```json\n{\"type\":\"test-report\",\"outcome\":\"fail\",\"findings\":[]}\n```" }
    ])
    report = TaskRunner.poll_for_report('sess-1', interval: 0, timeout: 5)
    assert_equal 'test-report', report['type']
    assert_equal 'fail', report['outcome']
  end

  def test_assistant_message_still_extracts
    stub_sequence([
      { 'role' => 'assistant', 'content' => "```json\n{\"type\":\"test-report\",\"outcome\":\"pass\",\"findings\":[]}\n```" }
    ])
    report = TaskRunner.poll_for_report('sess-1', interval: 0, timeout: 5)
    assert_equal 'test-report', report['type']
    assert_equal 'pass', report['outcome']
  end

  def test_failed_status_escalates_even_on_non_assistant_role
    stub_sequence([
      { 'role' => 'user', 'status' => 'failed', 'content' => 'boom' }
    ])
    report = TaskRunner.poll_for_report('sess-2', interval: 0, timeout: 5)
    assert_equal 'task-failed', report['type']
  end
end

class ExtractReportExamplesTest < Minitest::Test
  require 'tempfile'

  def with_task_file(body)
    Tempfile.create(['task', '.md']) do |f|
      f.write(body)
      f.flush
      yield f.path
    end
  end

  def test_returns_empty_when_path_nil
    assert_equal [], TaskRunner.extract_report_examples(nil)
  end

  def test_returns_empty_when_file_missing
    assert_equal [], TaskRunner.extract_report_examples('/nonexistent/task.md')
  end

  def test_extracts_unindented_block
    body = <<~MD
      Some prose.

      ```json
      {
        "type": "test-report",
        "outcome": "pass"
      }
      ```
    MD
    with_task_file(body) do |path|
      examples = TaskRunner.extract_report_examples(path)
      assert_equal 1, examples.length
      assert_includes examples[0], '"type": "test-report"'
      # Round-trips through JSON parse cleanly.
      assert_equal 'pass', JSON.parse(examples[0])['outcome']
    end
  end

  def test_extracts_indented_block_and_dedents
    # Mirrors tasks/issue-triage.md: fenced block sits inside a numbered list.
    body = <<~MD
      1. **Report** — output:

         ```json
         {
           "type": "triage-report",
           "next_issue": null
         }
         ```
    MD
    with_task_file(body) do |path|
      examples = TaskRunner.extract_report_examples(path)
      assert_equal 1, examples.length
      # Dedented body must parse as JSON (would fail with leading 3-space indent
      # only if JSON.parse rejected it — it doesn't, but verify dedent ran).
      refute_match(/\A   /, examples[0])
      assert_equal 'triage-report', JSON.parse(examples[0])['type']
    end
  end

  def test_skips_non_json_fenced_blocks
    body = <<~MD
      ```bash
      gh pr checkout x
      ```

      ```json
      { "type": "test-report", "outcome": "pass" }
      ```
    MD
    with_task_file(body) do |path|
      examples = TaskRunner.extract_report_examples(path)
      assert_equal 1, examples.length
    end
  end

  def test_skips_unknown_types
    body = <<~MD
      ```json
      { "type": "pr-update-report" }
      ```

      ```json
      { "type": "test-report", "outcome": "pass" }
      ```
    MD
    with_task_file(body) do |path|
      examples = TaskRunner.extract_report_examples(path)
      assert_equal 1, examples.length
      assert_includes examples[0], '"test-report"'
    end
  end

  def test_skips_invalid_json
    body = <<~MD
      ```json
      { "type": "test-report", broken
      ```

      ```json
      { "type": "test-report", "outcome": "pass" }
      ```
    MD
    with_task_file(body) do |path|
      examples = TaskRunner.extract_report_examples(path)
      assert_equal 1, examples.length
    end
  end

  def test_real_task_files_yield_at_least_one_example_each
    tasks_dir = File.expand_path('../tasks', __dir__)
    Dir["#{tasks_dir}/*.md"].each do |path|
      examples = TaskRunner.extract_report_examples(path)
      refute_empty examples, "expected #{File.basename(path)} to have at least one recognized JSON example"
    end
  end
end

class DedentTest < Minitest::Test
  def test_no_indent_returns_unchanged
    text = "foo\nbar"
    assert_equal text, TaskRunner.dedent(text)
  end

  def test_strips_common_indent
    text = "  foo\n  bar"
    assert_equal "foo\nbar", TaskRunner.dedent(text)
  end

  def test_preserves_relative_indent
    text = "  foo\n    bar"
    assert_equal "foo\n  bar", TaskRunner.dedent(text)
  end

  def test_blank_lines_do_not_affect_min_indent
    text = "  foo\n\n  bar"
    assert_equal "foo\n\n  bar".sub('  bar', 'bar'), TaskRunner.dedent(text)
  end

  def test_handles_empty_input
    assert_equal '', TaskRunner.dedent('')
  end
end

class RecoveryPromptTest < Minitest::Test
  require 'tempfile'

  def test_returns_base_prompt_when_no_path
    prompt = TaskRunner.recovery_prompt(nil)
    assert_equal TaskRunner::RECOVERY_PROMPT_BASE, prompt
  end

  def test_returns_base_prompt_when_no_examples_extracted
    Tempfile.create(['task', '.md']) do |f|
      f.write("# Task with no JSON examples\n\nJust prose.\n")
      f.flush
      assert_equal TaskRunner::RECOVERY_PROMPT_BASE, TaskRunner.recovery_prompt(f.path)
    end
  end

  def test_appends_examples_when_present
    tasks_dir = File.expand_path('../tasks', __dir__)
    prompt = TaskRunner.recovery_prompt(File.join(tasks_dir, 'test.md'))
    assert_includes prompt, TaskRunner::RECOVERY_PROMPT_BASE
    assert_includes prompt, 'expected JSON shape for this task'
    assert_includes prompt, '"type": "test-report"'
    assert_includes prompt, '"type": "test-blocked"'
    # Examples are wrapped as fenced json blocks.
    assert_match(/```json\n\{/, prompt)
  end
end

class SendRecoveryReminderWithTaskPathTest < Minitest::Test
  def setup
    @original_send_message = Synthup.method(:send_message)
  end

  def teardown
    Synthup.define_singleton_method(:send_message, @original_send_message)
  end

  def test_prompt_includes_task_examples_when_task_path_given
    captured = nil
    Synthup.define_singleton_method(:send_message) do |_sid, prompt:, model: nil|
      captured = prompt
      nil
    end
    task_path = File.expand_path('../tasks/test.md', __dir__)
    TaskRunner.send_recovery_reminder('sess-1', 'sess-1', 900, 0.5, task_path)
    refute_nil captured
    assert_includes captured, 'expected JSON shape for this task'
    assert_includes captured, '"type": "test-report"'
    assert_includes captured, '"type": "test-blocked"'
  end

  def test_prompt_falls_back_to_base_when_task_path_nil
    captured = nil
    Synthup.define_singleton_method(:send_message) do |_sid, prompt:, model: nil|
      captured = prompt
      nil
    end
    TaskRunner.send_recovery_reminder('sess-1', 'sess-1', 900, 0.5, nil)
    assert_equal TaskRunner::RECOVERY_PROMPT_BASE, captured
  end
end
