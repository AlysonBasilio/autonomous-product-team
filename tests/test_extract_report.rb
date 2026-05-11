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
        "next_issue": { "id": "PROJ-1", "title": "X", "summary": "Y", "issue_type": "implementation" },
        "considered": ["PROJ-1"],
        "dependencies_checked": []
      }
      ```
    MD
    report = extract(content)
    assert_equal 'triage-report', report['type']
    assert_equal 'PROJ-1', report['next_issue']['id']
  end

  def test_triage_report_rejected_when_next_issue_missing_from_considered
    # The agent claimed PROJ-1 is ready but didn't list it in `considered`,
    # which means it never ran the per-issue dependency lookup on it. This is
    # the failure mode that let ENG-1982 ship as "ready" while blocked.
    content = <<~MD
      ```json
      {
        "type": "triage-report",
        "next_issue": { "id": "PROJ-1", "title": "X", "summary": "Y" },
        "issue_type": "implementation",
        "considered": ["PROJ-2", "PROJ-3"],
        "dependencies_checked": []
      }
      ```
    MD
    assert_nil extract(content)
  end

  def test_triage_report_rejected_when_considered_missing
    content = <<~MD
      ```json
      {
        "type": "triage-report",
        "next_issue": { "id": "PROJ-1", "title": "X", "summary": "Y" },
        "issue_type": "implementation"
      }
      ```
    MD
    assert_nil extract(content)
  end

  def test_triage_report_with_null_next_issue_does_not_require_considered
    # If no issue is ready there's nothing to attest — the consistency rule
    # only applies when a `next_issue` is named.
    content = <<~MD
      ```json
      { "type": "triage-report", "next_issue": null }
      ```
    MD
    assert_equal 'triage-report', extract(content)['type']
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

  # Rejection-reason path — the poller sends these strings back to the agent
  # as corrective feedback so it actually re-runs the missing lookups.
  def reason(content)
    TaskRunner.report_rejection_reason(content)
  end

  def test_rejection_reason_names_the_missing_issue
    content = <<~MD
      ```json
      {
        "type": "triage-report",
        "next_issue": { "id": "ENG-1982", "title": "X", "summary": "Y" },
        "issue_type": "implementation",
        "considered": ["ENG-1001", "ENG-1002"],
        "dependencies_checked": []
      }
      ```
    MD
    msg = reason(content)
    assert_includes msg, 'ENG-1982'
    assert_includes msg, 'considered'
  end

  def test_rejection_reason_flags_missing_considered_array
    content = <<~MD
      ```json
      {
        "type": "triage-report",
        "next_issue": { "id": "ENG-1", "title": "X", "summary": "Y" },
        "issue_type": "implementation"
      }
      ```
    MD
    msg = reason(content)
    refute_nil msg
    assert_includes msg, '`considered`'
  end

  def test_rejection_reason_nil_when_report_valid
    content = <<~MD
      ```json
      {
        "type": "triage-report",
        "next_issue": { "id": "ENG-1", "title": "X", "summary": "Y" },
        "issue_type": "implementation",
        "considered": ["ENG-1"],
        "dependencies_checked": []
      }
      ```
    MD
    assert_nil reason(content)
  end

  def test_rejection_reason_nil_when_no_report_block
    assert_nil reason("just some prose, no fenced block")
  end

  def test_rejection_reason_nil_for_unrelated_report_types
    content = <<~MD
      ```json
      { "type": "task-complete", "task": "x", "issue_id": "1", "pr_url": "u", "summary": "s" }
      ```
    MD
    assert_nil reason(content)
  end
end
