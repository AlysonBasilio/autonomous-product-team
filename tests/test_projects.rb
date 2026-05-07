# frozen_string_literal: true
#
# Unit tests for the Projects module: github_repo resolution, persistence, and
# back-fill of legacy records that predate the github_repo field.

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'json'

require_relative '../orchestrator/storage'
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
  def setup
    @prev_storage = Storage.default
    @tmpdir = Dir.mktmpdir('projects_test')
    Storage.default = Storage::JsonFileStorage.new(@tmpdir)
  end

  def teardown
    Storage.default = @prev_storage
    FileUtils.rm_rf(@tmpdir)
  end

  def test_github_url_creates_record_with_repo
    p = Projects.create(project_url: 'https://github.com/foo/bar')
    assert_equal 'foo/bar', p.github_repo
    assert_equal 'https://github.com/foo/bar', p.project_url
    state = Storage.default.read_json(Projects.path_for(p.id))
    assert_equal 'foo/bar', state['github_repo']
  end

  def test_linear_url_with_explicit_repo
    p = Projects.create(
      project_url: 'https://linear.app/acme/projects/foo',
      github_repo: 'foo/bar'
    )
    assert_equal 'foo/bar', p.github_repo
    assert_equal 'https://linear.app/acme/projects/foo', p.project_url
  end

  def test_linear_url_without_repo_raises_and_writes_no_file
    assert_raises(ArgumentError) do
      Projects.create(project_url: 'https://linear.app/acme/projects/foo')
    end
    assert_empty Storage.default.list(Projects::PROJECTS_DIR)
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
end

class TestProjectsBackfill < Minitest::Test
  def setup
    @prev_storage = Storage.default
    @tmpdir = Dir.mktmpdir('projects_test')
    Storage.default = Storage::JsonFileStorage.new(@tmpdir)
  end

  def teardown
    Storage.default = @prev_storage
    FileUtils.rm_rf(@tmpdir)
  end

  def write_legacy(id, project_url)
    legacy = {
      'version'     => 2,
      'id'          => id,
      'project_url' => project_url,
      'local_path'  => nil,
      'created_at'  => '2025-01-01T00:00:00Z',
      'status'      => 'running',
      'currentTask' => nil,
      'escalation'  => nil,
      'history'     => []
    }
    Storage.default.write_json(Projects.path_for(id), legacy)
  end

  def test_find_backfills_github_repo_from_github_url
    write_legacy('legacy-gh', 'https://github.com/foo/bar')
    p = Projects.find('legacy-gh')
    refute_nil p
    assert_equal 'foo/bar', p.github_repo
  end

  def test_find_returns_nil_repo_for_legacy_linear_record
    write_legacy('legacy-linear', 'https://linear.app/acme/projects/foo')
    p = Projects.find('legacy-linear')
    refute_nil p
    assert_nil p.github_repo
  end

  def test_list_backfills_repos
    write_legacy('legacy-gh', 'https://github.com/foo/bar')
    write_legacy('legacy-linear', 'https://linear.app/acme/projects/foo')
    by_id = Projects.list.to_h { |p| [p.id, p] }
    assert_equal 'foo/bar', by_id['legacy-gh'].github_repo
    assert_nil by_id['legacy-linear'].github_repo
  end
end
