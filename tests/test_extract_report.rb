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

  def test_fenced_json_with_nested_object
    content = <<~MD
      Some prose.

      ```json
      {
        "type": "triage-report",
        "next_issue": { "id": "PROJ-1", "title": "X", "summary": "Y", "issue_type": "implementation" }
      }
      ```
    MD
    report = extract(content)
    assert_equal 'triage-report', report['type']
    assert_equal 'PROJ-1', report['next_issue']['id']
  end

  def test_fenced_json_with_arrays
    content = <<~MD
      ```json
      {
        "type": "split-report",
        "source_issue_id": "PROJ-1",
        "reason": "too big",
        "issues": [
          { "title": "A", "description": "x" },
          { "title": "B", "description": "y", "depends_on": ["A"] }
        ]
      }
      ```
    MD
    report = extract(content)
    assert_equal 'split-report', report['type']
    assert_equal 2, report['issues'].length
    assert_equal ['A'], report['issues'][1]['depends_on']
  end

  def test_bare_fence_with_valid_json_still_matches
    # The extractor accepts ``` (no language tag) for resilience.
    content = "```\n{\"type\": \"task-failed\", \"task\": \"x\", \"failure\": \"y\"}\n```\n"
    report = extract(content)
    assert_equal 'task-failed', report['type']
  end

  def test_yaml_style_block_returns_nil
    # This is the exact failure mode that broke session 05aa1a35... — a fenced
    # block with `type: foo` (YAML-ish) instead of JSON. Must NOT match.
    content = <<~MD
      ```
      type: task-failed
      task: tasks/issue-triage.md
      failure: The project repository does not exist
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
    content = '{ "type": "triage-report", "next_issue": null }'
    assert_nil extract(content)
  end

  def test_first_valid_block_wins_when_multiple
    content = <<~MD
      ```json
      { "type": "triage-report", "next_issue": null }
      ```

      ```json
      { "type": "task-complete", "task": "x", "issue_id": "1", "pr_url": "u", "summary": "s" }
      ```
    MD
    assert_equal 'triage-report', extract(content)['type']
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
      { "type": "triage-report", malformed:
      ```
    MD
    assert_nil extract(content)
  end

  def test_non_string_input
    assert_nil extract(nil)
    assert_nil extract(123)
    assert_nil extract({ 'type' => 'triage-report' })
  end
end
