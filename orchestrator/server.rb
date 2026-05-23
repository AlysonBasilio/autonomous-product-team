require 'sinatra/base'
require 'json'
require_relative 'config'
require_relative 'issues'
require_relative 'synthup'
require_relative 'db'

class OrchestratorServer < Sinatra::Base
  set :server,         :puma
  set :logging,        false
  set :port_value,     4242
  set :interactive_mode, false

  if ENV['ORCHESTRATOR_PASSWORD'].to_s.strip != ''
    use Rack::Auth::Basic, 'Orchestrator' do |u, p|
      Rack::Utils.secure_compare(ENV.fetch('ORCHESTRATOR_USERNAME', 'admin'), u) &&
        Rack::Utils.secure_compare(ENV['ORCHESTRATOR_PASSWORD'], p)
    end
  end

  IssueControl = Struct.new(
    :paused, :cancel_requested, :pending_approvals,
    keyword_init: true
  )

  class << self
    def controls
      @controls ||= {}
    end

    def controls_guard
      @controls_guard ||= Mutex.new
    end

    def issue_threads
      @issue_threads ||= {}
    end

    def issue_threads_mutex
      @issue_threads_mutex ||= Mutex.new
    end

    def ctl(issue_id)
      controls_guard.synchronize do
        controls[issue_id] ||= IssueControl.new(
          paused: false, cancel_requested: false, pending_approvals: []
        )
      end
    end

    def forget(issue_id)
      controls_guard.synchronize { controls.delete(issue_id) }
      issue_threads_mutex.synchronize { issue_threads.delete(issue_id) }
    end

    def thread_alive?(issue_id)
      issue_threads_mutex.synchronize { issue_threads[issue_id]&.alive? }
    end

    def spawn_issue_thread(issue, port:, interactive:, initial_action:)
      t = Thread.new do
        run_issue_loop(issue.id,
                       initial_action: initial_action,
                       port:           port,
                       interactive:    interactive,
                       control:        ctl(issue.id))
        issue_threads_mutex.synchronize { issue_threads.delete(issue.id) }
      end
      issue_threads_mutex.synchronize { issue_threads[issue.id] = t }
      t
    end
  end

  def self.build_state_payload
    cfg    = Config.load
    issues = Issue.order(:created_at).to_a

    issues_payload = issues.map do |i|
      c             = ctl(i.id)
      ct            = i.current_task || {}
      first_approval = c.pending_approvals&.first
      approval_meta  = first_approval && {
        issue_title: first_approval[:issue_title],
        issue_id:    first_approval[:issue_id],
        pr_url:      first_approval[:pr_url],
        summary:     first_approval[:summary]
      }

      {
        id:              i.id,
        title:           i.title,
        input_text:      i.input_text,
        repo_url:        i.repo_url,
        lifecycle_stage: i.lifecycle_stage,
        paused:          c.paused,
        thread_alive:    thread_alive?(i.id),
        current_task:    ct.empty? ? nil : ct,
        escalation:      i.escalation,
        pending_approval: approval_meta,
        history:         (Array(i.history)).last(20)
      }.compact
    end

    {
      synthup_configured: cfg.synthup_configured?,
      synthup:            { tenant:           cfg.tenant,
                            tenant_from_env:  Config.tenant_from_env?,
                            api_key_from_env: Config.api_key_from_env? },
      issues:             issues_payload
    }
  end

  # ── Routes ─────────────────────────────────────────────────────────────────

  get '/' do
    send_file File.join(File.dirname(__FILE__), 'ui.html')
  end

  get '/api/state' do
    content_type :json
    self.class.build_state_payload.to_json
  end

  post '/api/issues' do
    body_params = JSON.parse(request.body.read) rescue {}
    input_text  = body_params['issue'].to_s.strip
    repo_url    = body_params['repo_url'].to_s.strip
    return json_error(400, 'issue is required')   if input_text.empty?
    return json_error(400, 'repo_url is required') if repo_url.empty?

    warn "[server] POST /api/issues repo=#{repo_url} issue=#{input_text.slice(0, 60).inspect}"
    issue = Issue.create!(input_text: input_text, repo_url: repo_url, lifecycle_stage: 'coding')
    warn "[server] issue created id=#{issue.id}"
    initial_action = { type: 'run-task', task: 'code.md', context: { input_text: input_text } }
    self.class.spawn_issue_thread(issue,
                                  port:           settings.port_value,
                                  interactive:    settings.interactive_mode,
                                  initial_action: initial_action)
    content_type :json
    { id: issue.id, title: issue.title || input_text }.to_json
  end

  delete '/api/issues/:id' do |id|
    return json_error(409, 'Cancel the issue before deleting') if self.class.thread_alive?(id)
    warn "[server] DELETE /api/issues/#{id}"
    Issue.find_by(id: id)&.destroy
    self.class.forget(id)
    json_ok
  end

  post '/api/approve' do
    body_params = JSON.parse(request.body.read) rescue {}
    c = resolve_control(body_params)
    approval = c&.pending_approvals&.first
    return json_error(409, 'No pending approval') unless approval
    warn "[server] POST /api/approve issue=#{body_params['issue_id']}"
    approval[:resolve].call('outcome'          => 'approved',
                            'user_feedback'    => nil,
                            'follow_up_issues' => body_params['follow_up_issues'])
    json_ok
  end

  post '/api/redirect' do
    body_params = JSON.parse(request.body.read) rescue {}
    c = resolve_control(body_params)
    approval = c&.pending_approvals&.first
    return json_error(409, 'No pending approval') unless approval
    warn "[server] POST /api/redirect issue=#{body_params['issue_id']} feedback=#{body_params['user_feedback'].to_s.slice(0, 60).inspect}"
    approval[:resolve].call('outcome'       => 'redirect',
                            'user_feedback' => body_params['user_feedback'] || '',
                            'follow_up_issues' => nil)
    json_ok
  end

  post '/api/reset-issue' do
    body_params = JSON.parse(request.body.read) rescue {}
    issue_id    = body_params['issue_id'].to_s.strip
    return json_error(400, 'issue_id required') if issue_id.empty?
    issue = Issue.find_by(id: issue_id)
    return json_error(404, 'Issue not found') unless issue
    warn "[server] POST /api/reset-issue id=#{issue_id}"
    Issues.clear_current_task(issue_id)
    Issues.clear_escalation(issue_id)
    unless self.class.thread_alive?(issue_id)
      initial_action = { type: 'run-task', task: issue.last_task || 'code.md',
                         context: { input_text: issue.input_text, pr_url: issue.last_pr_url,
                                    issue_id: Issues.last_issue_id(issue) }.compact }
      warn "[server] spawning thread for reset id=#{issue_id} task=#{initial_action[:task]}"
      self.class.spawn_issue_thread(issue,
                                    port:           settings.port_value,
                                    interactive:    settings.interactive_mode,
                                    initial_action: initial_action)
    end
    json_ok
  end

  post '/api/resolve-escalation' do
    body_params = JSON.parse(request.body.read) rescue {}
    issue_id    = body_params['issue_id'].to_s.strip
    return json_error(400, 'issue_id required') if issue_id.empty?
    warn "[server] POST /api/resolve-escalation id=#{issue_id}"
    Issues.clear_escalation(issue_id)
    json_ok
  end

  post '/api/dismiss-escalation' do
    body_params = JSON.parse(request.body.read) rescue {}
    issue_id    = body_params['issue_id'].to_s.strip
    return json_error(400, 'issue_id required') if issue_id.empty?
    warn "[server] POST /api/dismiss-escalation id=#{issue_id}"
    Issues.clear_escalation(issue_id)
    Issue.find_by(id: issue_id)&.update!(lifecycle_stage: 'done')
    c = self.class.ctl(issue_id)
    c.cancel_requested = true if c
    json_ok
  end

  post '/api/cancel' do
    body_params = JSON.parse(request.body.read) rescue {}
    c = resolve_control(body_params)
    return json_error(400, 'issue_id required') unless c
    warn "[server] POST /api/cancel id=#{body_params['issue_id']}"
    c.pending_approvals&.first&.dig(:resolve)&.call('outcome' => 'cancelled')
    c.cancel_requested = true
    c.paused = false
    json_ok
  end

  post '/api/pause' do
    body_params = JSON.parse(request.body.read) rescue {}
    c = resolve_control(body_params)
    return json_error(400, 'issue_id required') unless c
    warn "[server] POST /api/pause id=#{body_params['issue_id']}"
    c.paused = true
    json_ok
  end

  post '/api/resume' do
    body_params = JSON.parse(request.body.read) rescue {}
    c = resolve_control(body_params)
    return json_error(400, 'issue_id required') unless c
    warn "[server] POST /api/resume id=#{body_params['issue_id']}"
    c.paused = false
    json_ok
  end

  # Save global Synthup credentials.
  post '/api/config' do
    body_params = JSON.parse(request.body.read) rescue {}
    tenant  = body_params['tenant'].to_s.strip
    api_key = body_params['api_key'].to_s.strip
    return json_error(400, 'tenant and api_key are required') if tenant.empty? || api_key.empty?
    warn "[server] POST /api/config tenant=#{tenant}"
    Config.save_synthup_credentials(tenant: tenant, api_key: api_key)
    Synthup.api_key = api_key
    json_ok
  end

  private

  def resolve_control(body_params)
    issue_id = body_params['issue_id'].to_s.strip
    return nil if issue_id.empty?
    self.class.ctl(issue_id)
  end

  def json_ok
    content_type :json
    { ok: true }.to_json
  end

  def json_error(code, msg)
    content_type :json
    status code
    { error: msg }.to_json
  end
end
