# frozen_string_literal: true
#
# HTTP-level tests for POST /api/projects: validates that github_repo is
# resolved/required at the API boundary and surfaces clear 400s.

require 'minitest/autorun'
require 'rack/test'
require 'fileutils'
require 'tmpdir'
require 'json'

require_relative '../orchestrator/storage'
require_relative '../orchestrator/state'
require_relative '../orchestrator/config'
require_relative '../orchestrator/projects'
require_relative '../orchestrator/server'

class TestPostProjects < Minitest::Test
  include Rack::Test::Methods

  def app
    OrchestratorServer
  end

  def setup
    @prev_storage = Storage.default
    @tmpdir = Dir.mktmpdir('server_test')
    Storage.default = Storage::JsonFileStorage.new(@tmpdir)
    @prev_host_auth = OrchestratorServer.host_authorization
    OrchestratorServer.set :host_authorization, { permitted_hosts: [] }
  end

  def teardown
    Storage.default = @prev_storage
    FileUtils.rm_rf(@tmpdir)
    OrchestratorServer.set :host_authorization, @prev_host_auth
  end

  def post_project(body)
    post '/api/projects', body.to_json, { 'CONTENT_TYPE' => 'application/json' }
  end

  def test_github_url_returns_200_with_github_repo
    post_project(project_url: 'https://github.com/foo/bar')
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'foo/bar', body['github_repo']
    assert_equal 'https://github.com/foo/bar', body['project_url']
  end

  def test_linear_url_with_github_repo_returns_200
    post_project(
      project_url: 'https://linear.app/acme/projects/foo',
      github_repo: 'foo/bar'
    )
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'foo/bar', body['github_repo']
    assert_equal 'https://linear.app/acme/projects/foo', body['project_url']
  end

  def test_linear_url_alone_returns_400
    post_project(project_url: 'https://linear.app/acme/projects/foo')
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body['error'], 'github_repo is required'
  end

  def test_empty_project_url_returns_400
    post_project(project_url: '')
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_includes body['error'], 'project_url is required'
  end

  def test_invalid_github_repo_returns_400
    post_project(
      project_url: 'https://linear.app/acme/projects/foo',
      github_repo: 'not a repo'
    )
    assert_equal 400, last_response.status
  end

  # Per-project control state must not leak between projects: pausing one
  # cannot pause another. This is the core invariant that makes parallel
  # project loops safe.
  def test_pause_is_isolated_per_project
    post_project(project_url: 'https://github.com/foo/a')
    a_id = JSON.parse(last_response.body)['id']
    post_project(project_url: 'https://github.com/foo/b')
    b_id = JSON.parse(last_response.body)['id']

    post '/api/pause', { project_id: a_id }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status

    assert OrchestratorServer.ctl(a_id).paused, 'project A should be paused'
    refute OrchestratorServer.ctl(b_id).paused, 'project B must NOT be paused'

    post '/api/resume', { project_id: a_id }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    refute OrchestratorServer.ctl(a_id).paused, 'project A should be resumed'
  ensure
    OrchestratorServer.forget(a_id) if a_id
    OrchestratorServer.forget(b_id) if b_id
  end
end
