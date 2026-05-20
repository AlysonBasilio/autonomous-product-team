# frozen_string_literal: true
#
# Unit tests for the Projects module: github_repo resolution and AR-backed
# persistence.

require 'minitest/autorun'

require_relative 'db_helper'
require_relative '../orchestrator/state'
require_relative '../orchestrator/projects'

class TestProjectsResolveGithubRepo < Minitest::Test
  def test_explicit_owner_repo_passes_through
    assert_equal 'foo/bar', Projects.resolve_github_repo(
      project_url: 'https://linear.app/acme/projects/x', github_repo: 'foo/bar'
    )
  end

  def test_explicit_full_url_normalizes
    assert_equal 'foo/bar', Projects.resolve_github_repo(
      project_url: 'https://linear.app/acme/projects/x',
      github_repo: 'https://github.com/foo/bar.git'
    )
  end

  def test_derives_from_github_project_url
    assert_equal 'foo/bar', Projects.resolve_github_repo(
      project_url: 'https://github.com/foo/bar', github_repo: nil
    )
  end

  def test_derives_from_github_project_url_with_trailing_segments
    assert_equal 'foo/bar', Projects.resolve_github_repo(
      project_url: 'https://github.com/foo/bar/issues/42', github_repo: nil
    )
  end

  def test_explicit_overrides_project_url
    assert_equal 'foo/bar', Projects.resolve_github_repo(
      project_url: 'https://github.com/baz/qux', github_repo: 'foo/bar'
    )
  end

  def test_linear_url_without_explicit_repo_raises
    err = assert_raises(ArgumentError) do
      Projects.resolve_github_repo(
        project_url: 'https://linear.app/acme/projects/x', github_repo: nil
      )
    end
    assert_includes err.message, 'github_repo is required'
  end

  def test_invalid_explicit_repo_raises
    assert_raises(ArgumentError) do
      Projects.resolve_github_repo(
        project_url: 'https://github.com/foo/bar', github_repo: 'not a repo'
      )
    end
  end
end

class TestProjectsCreate < Minitest::Test
  include DBHelper

  def setup
    setup_in_memory_db
  end

  def teardown
    teardown_in_memory_db
  end

  def test_github_url_creates_record_with_repo
    p = Projects.create(project_url: 'https://github.com/foo/bar')
    assert_equal 'foo/bar', p.github_repo
    assert_equal 'https://github.com/foo/bar', p.project_url
    persisted = Project.find(p.id)
    assert_equal 'foo/bar', persisted.github_repo
    assert persisted.state.present?, 'project_state row must be created alongside project'
  end

  def test_linear_url_with_explicit_repo
    p = Projects.create(
      project_url: 'https://linear.app/acme/projects/foo',
      github_repo: 'foo/bar'
    )
    assert_equal 'foo/bar', p.github_repo
    assert_equal 'https://linear.app/acme/projects/foo', p.project_url
  end

  def test_linear_url_without_repo_raises_and_writes_no_record
    assert_raises(ArgumentError) do
      Projects.create(project_url: 'https://linear.app/acme/projects/foo')
    end
    assert_equal 0, Project.count
  end

  def test_full_url_form_normalizes
    p = Projects.create(
      project_url: 'https://linear.app/acme/projects/foo',
      github_repo: 'https://github.com/foo/bar.git'
    )
    assert_equal 'foo/bar', p.github_repo
  end

  def test_invalid_github_repo_raises
    assert_raises(ArgumentError) do
      Projects.create(
        project_url: 'https://linear.app/acme/projects/foo',
        github_repo: 'nope'
      )
    end
  end

  def test_explicit_repo_overrides_github_project_url
    p = Projects.create(
      project_url: 'https://github.com/baz/qux',
      github_repo: 'foo/bar'
    )
    assert_equal 'foo/bar', p.github_repo
  end

  def test_idempotent_create_patches_changed_fields
    p1 = Projects.create(project_url: 'https://github.com/foo/bar')
    p2 = Projects.create(
      project_url: 'https://github.com/foo/bar',
      github_repo: 'foo/baz',
      local_path:  '/tmp/repo'
    )
    assert_equal p1.id, p2.id
    assert_equal 'foo/baz', p2.github_repo
    assert_equal '/tmp/repo', p2.local_path
  end

  def test_delete_removes_project_state_and_history
    p = Projects.create(project_url: 'https://github.com/foo/bar')
    State.record_history(p.id, {
      'task' => 'triage.md', 'session_id' => 'abc',
      'completed_at' => Time.now.utc.iso8601, 'duration_s' => 5,
      'report' => { 'outcome' => 'ok' }
    })
    Projects.delete(p.id)
    assert_nil Projects.find(p.id)
    assert_equal 0, ProjectState.where(project_id: p.id).count
    assert_equal 0, ProjectHistoryEntry.where(project_id: p.id).count
  end
end
