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
    result = TaskRunner.send_recovery_reminder('sess-1', 'sess-1', 900, 0.5)
    assert_equal true, result
    assert_equal 1, captured.length
    assert_equal 'sess-1', captured[0][:session_id]
    assert_includes captured[0][:prompt], 'final JSON report'
  end

  def test_returns_false_on_synthup_error
    Synthup.define_singleton_method(:send_message) do |*_args, **_kwargs|
      raise Synthup::Error.new(500, 'boom')
    end
    result = TaskRunner.send_recovery_reminder('sess-1', 'sess-1', 900, 0.5)
    assert_equal false, result
  end

  def test_returns_false_on_transient_network_error
    Synthup.define_singleton_method(:send_message) do |*_args, **_kwargs|
      raise Net::OpenTimeout, 'connect timed out'
    end
    require 'net/http'
    result = TaskRunner.send_recovery_reminder('sess-1', 'sess-1', 900, 0.5)
    assert_equal false, result
  end
end

class KnownReportTypesTest < Minitest::Test
  def test_recovery_exhausted_is_known
    assert_includes TaskRunner::KNOWN_REPORT_TYPES, 'recovery-exhausted'
  end
end
