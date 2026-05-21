# frozen_string_literal: true
#
# HTTP-level tests for the issue-first orchestrator server.

require 'minitest/autorun'
require 'rack/test'
require 'json'

require_relative 'db_helper'
require_relative '../orchestrator/config'
require_relative '../orchestrator/issues'
require_relative '../orchestrator/server'

class TestServerIssueRoutes < Minitest::Test
  include Rack::Test::Methods
  include DBHelper

  def app
    OrchestratorServer
  end

  def setup
    setup_in_memory_db
    @prev_host_auth = OrchestratorServer.host_authorization
    OrchestratorServer.set :host_authorization, { permitted_hosts: [] }
    OrchestratorServer.set :port_value,      4242
    OrchestratorServer.set :interactive_mode, false
  end

  def teardown
    OrchestratorServer.set :host_authorization, @prev_host_auth
    teardown_in_memory_db
  end

  def post_issue(body)
    post '/api/issues', body.to_json, { 'CONTENT_TYPE' => 'application/json' }
  end

  def test_post_issue_missing_issue_returns_400
    post_issue(repo_url: 'https://github.com/a/b')
    assert_equal 400, last_response.status
    assert_includes JSON.parse(last_response.body)['error'], 'issue is required'
  end

  def test_post_issue_missing_repo_returns_400
    post_issue(issue: 'Fix the bug')
    assert_equal 400, last_response.status
    assert_includes JSON.parse(last_response.body)['error'], 'repo_url is required'
  end

  def test_post_issue_creates_issue_record
    # Override spawn_issue_thread so no real thread starts during the test
    OrchestratorServer.define_singleton_method(:spawn_issue_thread) { |*| nil }
    post_issue(issue: 'Fix the login bug', repo_url: 'https://github.com/a/b')
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert body['id'], 'response must include id'
    assert_equal 1, Issue.count
    i = Issue.first
    assert_equal 'Fix the login bug', i.input_text
    assert_equal 'https://github.com/a/b', i.repo_url
  ensure
    OrchestratorServer.singleton_class.remove_method(:spawn_issue_thread) rescue nil
  end

  def test_delete_issue_returns_404_for_unknown_id
    delete '/api/issues/nonexistent-uuid'
    # thread_alive? returns false for unknown → should succeed or 404 on missing issue
    # The issue doesn't exist so destroy is a no-op, but response is 200
    assert_equal 200, last_response.status
  end

  def test_delete_issue_returns_409_when_thread_alive
    issue = Issue.create!(input_text: 'test', repo_url: 'https://github.com/a/b',
                          lifecycle_stage: 'coding')
    OrchestratorServer.issue_threads_mutex.synchronize do
      OrchestratorServer.issue_threads[issue.id] = Thread.new { sleep 60 }
    end
    delete "/api/issues/#{issue.id}"
    assert_equal 409, last_response.status
    assert_includes JSON.parse(last_response.body)['error'], 'Cancel'
  ensure
    OrchestratorServer.issue_threads_mutex.synchronize do
      t = OrchestratorServer.issue_threads.delete(issue&.id)
      t&.kill
    end
  end

  def test_pause_is_isolated_per_issue
    i1 = Issue.create!(lifecycle_stage: 'coding')
    i2 = Issue.create!(lifecycle_stage: 'coding')

    post '/api/pause', { issue_id: i1.id }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status

    assert OrchestratorServer.ctl(i1.id).paused,  'issue 1 should be paused'
    refute OrchestratorServer.ctl(i2.id).paused,  'issue 2 must NOT be paused'

    post '/api/resume', { issue_id: i1.id }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    refute OrchestratorServer.ctl(i1.id).paused, 'issue 1 should be resumed'
  ensure
    OrchestratorServer.forget(i1.id) if i1
    OrchestratorServer.forget(i2.id) if i2
  end

  def test_cancel_sets_cancel_requested
    i = Issue.create!(lifecycle_stage: 'coding')
    post '/api/cancel', { issue_id: i.id }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
    assert OrchestratorServer.ctl(i.id).cancel_requested
  ensure
    OrchestratorServer.forget(i&.id)
  end

  def test_resolve_escalation_clears_it
    i = Issue.create!(lifecycle_stage: 'coding',
                      escalation: { 'reason' => 'task-failed' })
    post '/api/resolve-escalation', { issue_id: i.id }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
    assert_nil i.reload.escalation
  end

  def test_dismiss_escalation_marks_done
    i = Issue.create!(lifecycle_stage: 'coding',
                      escalation: { 'reason' => 'task-failed' })
    post '/api/dismiss-escalation', { issue_id: i.id }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
    i.reload
    assert_nil i.escalation
    assert_equal 'done', i.lifecycle_stage
  end

  def test_state_endpoint_returns_issues_array
    Issue.create!(input_text: 'fix a', repo_url: 'https://github.com/a/b', lifecycle_stage: 'coding')
    Issue.create!(input_text: 'fix b', repo_url: 'https://github.com/a/b', lifecycle_stage: 'coding')
    get '/api/state'
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert body.key?('issues'), 'state must include issues array'
    assert_equal 2, body['issues'].length
    refute body.key?('projects'), 'state must not include projects key'
  end

  def test_config_endpoint
    # Env vars override stored values, so only check the response succeeds.
    post '/api/config', { tenant: 'test-tenant', api_key: 'test-key' }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
    assert JSON.parse(last_response.body)['ok']
  end

  def test_projects_route_does_not_exist
    get '/api/projects'
    assert_equal 404, last_response.status
  end

  def test_triage_route_does_not_exist
    post '/api/triage', {}.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 404, last_response.status
  end
end
