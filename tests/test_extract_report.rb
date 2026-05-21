#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Unit tests for TaskRunner.extract_report — guards the wire format between
# Synthup task agents and the orchestrator. The agent emits a fenced JSON
# block; extract_report must match it (and only it).
#
# Run: ruby tests/test_extract_report.rb

require 'minitest/autorun'

orchestrator_dir = File.expand_path('../orchestrator', __dir__)
$LOAD_PATH.unshift(orchestrator_dir)
require 'task_runner'

class ExtractReportTest < Minitest::Test
  def extract(content)
    TaskRunner.extract_report(content)
  end

  def test_task_complete_extracted
    content = <<~MD
      Some prose.

      ```json
      {
        "type": "task-complete",
        "task": "tasks/code.md",
        "issue_id": "ENG-1",
        "pr_url": "https://github.com/x/y/pull/1",
        "summary": "Fixed the bug"
      }
      ```
    MD
    report = extract(content)
    assert_equal 'task-complete', report['type']
    assert_equal 'ENG-1', report['issue_id']
  end

  def test_test_report_extracted
    content = <<~MD
      ```json
      { "type": "test-report", "issue_id": "ENG-1", "pr_url": "u", "outcome": "pass" }
      ```
    MD
    report = extract(content)
    assert_equal 'test-report', report['type']
    assert_equal 'pass', report['outcome']
  end

  def test_task_failed_extracted
    content = <<~MD
      ```json
      { "type": "task-failed", "task": "tasks/code.md", "failure": "CI red" }
      ```
    MD
    assert_equal 'task-failed', extract(content)['type']
  end

  def test_demo_review_pending_extracted
    content = <<~MD
      ```json
      {
        "type": "demo-review-pending",
        "issue_id": "ENG-1",
        "pr_url": "u",
        "summary": "Looks good"
      }
      ```
    MD
    assert_equal 'demo-review-pending', extract(content)['type']
  end

  def test_recovery_exhausted_extracted
    content = <<~MD
      ```json
      { "type": "recovery-exhausted", "details": "Timed out after 1800s" }
      ```
    MD
    assert_equal 'recovery-exhausted', extract(content)['type']
  end

  def test_fenced_json_with_nested_object
    content = <<~MD
      ```json
      {
        "type": "task-complete",
        "task": "tasks/code.md",
        "issue_id": "PROJ-1",
        "pr_url": "u",
        "summary": "done"
      }
      ```
    MD
    report = extract(content)
    assert_equal 'task-complete', report['type']
    assert_equal 'PROJ-1', report['issue_id']
  end

  def test_bare_fence_with_valid_json_still_matches
    # The extractor accepts ``` (no language tag) for resilience.
    content = "```\n{\"type\": \"task-failed\", \"task\": \"x\", \"failure\": \"y\"}\n```\n"
    report = extract(content)
    assert_equal 'task-failed', report['type']
  end

  def test_yaml_style_block_returns_nil
    # A fenced block with `type: foo` (YAML-ish) instead of JSON must NOT match.
    content = <<~MD
      ```
      type: task-failed
      task: tasks/code.md
      failure: oops
      ```
    MD
    assert_nil extract(content)
  end

  def test_unknown_type_returns_nil
    content = <<~MD
      ```json
      { "type": "bogus-not-a-real-type", "x": 1 }
      ```
    MD
    assert_nil extract(content)
  end

  def test_no_fence_returns_nil
    content = '{ "type": "task-complete", "issue_id": "1", "pr_url": "u", "summary": "s" }'
    assert_nil extract(content)
  end

  def test_first_valid_block_wins_when_multiple
    content = <<~MD
      ```json
      { "type": "task-complete", "task": "x", "issue_id": "1", "pr_url": "u", "summary": "s" }
      ```

      ```json
      { "type": "test-report", "outcome": "pass", "issue_id": "1", "pr_url": "u" }
      ```
    MD
    assert_equal 'task-complete', extract(content)['type']
  end

  def test_skips_unknown_type_finds_known_one_later
    content = <<~MD
      ```json
      { "type": "not-a-known-type" }
      ```

      ```json
      { "type": "task-complete", "task": "x", "issue_id": "1", "pr_url": "u", "summary": "s" }
      ```
    MD
    assert_equal 'task-complete', extract(content)['type']
  end

  def test_malformed_json_in_fence_returns_nil
    content = <<~MD
      ```json
      { "type": "task-failed", malformed:
      ```
    MD
    assert_nil extract(content)
  end

  def test_non_string_input
    assert_nil extract(nil)
    assert_nil extract(123)
    assert_nil extract({ 'type' => 'task-complete' })
  end

  def test_all_current_types_are_extractable
    %w[task-complete test-report task-failed
       demo-review-pending recovery-exhausted blocked].each do |type|
      content = "```json\n{\"type\": \"#{type}\"}\n```"
      report = extract(content)
      assert_equal type, report['type'], "expected #{type} to be extractable"
    end
  end
end
