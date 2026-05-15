require 'sinatra/base'
require 'json'
require_relative 'state'
require_relative 'config'
require_relative 'projects'
require_relative 'synthup'

class OrchestratorServer < Sinatra::Base
  set :server, :puma
  set :logging, false

  if ENV['ORCHESTRATOR_PASSWORD'].to_s.strip != ''
    use Rack::Auth::Basic, 'Orchestrator' do |u, p|
      Rack::Utils.secure_compare(ENV.fetch('ORCHESTRATOR_USERNAME', 'admin'), u) &&
        Rack::Utils.secure_compare(ENV['ORCHESTRATOR_PASSWORD'], p)
    end
  end

  # Per-project control flags. One struct per project_id; the orchestration
  # loop reads its own slot, so projects don't share pause/cancel/approval
  # state.
  ProjectControl = Struct.new(
    :paused, :triage_requested, :cancel_requested,
    :resume_polling_requested, :pending_approval, :pending_next_action,
    keyword_init: true
  )

  class << self
    def controls
      @controls ||= {}
    end

    def controls_guard
      @controls_guard ||= Mutex.new
    end

    def ctl(project_id)
      controls_guard.synchronize do
        controls[project_id] ||= ProjectControl.new(
          paused: false, triage_requested: false, cancel_requested: false,
          resume_polling_requested: false, pending_approval: nil, pending_next_action: nil
        )
      end
    end

    def forget(project_id)
      controls_guard.synchronize { controls.delete(project_id) }
    end
  end

  def self.build_state_payload
    cfg          = Config.load
    projects     = Projects.list
    projects_state = projects.each_with_object({}) do |p, h|
      s = State.load(p.id) || {}
      c = ctl(p.id)
      approval_meta = c.pending_approval && {
        issue_title: c.pending_approval[:issue_title],
        issue_id:    c.pending_approval[:issue_id],
        pr_url:      c.pending_approval[:pr_url],
        summary:     c.pending_approval[:summary]
      }
      h[p.id] = {
        status:              s['status'],
        paused:              c.paused,
        currentTask:         s['currentTask'],
        history:             (s['history'] || []).last(20),
        escalation:          s['escalation'],
        pending_approval:    approval_meta,
        pending_next_action: c.pending_next_action
      }
    end

    {
      synthup_configured: cfg.synthup_configured?,
      synthup:            { tenant: cfg.tenant,
                            tenant_from_env: Config.tenant_from_env?,
                            api_key_from_env: Config.api_key_from_env? },
      projects:           projects.map(&:to_h),
      active_project_id:  cfg.active_project_id,
      projects_state:     projects_state
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

  post '/api/approve' do
    body_params = JSON.parse(request.body.read) rescue {}
    c = control_for(body_params)
    return json_error(409, 'No pending approval') unless c&.pending_approval
    c.pending_approval[:resolve].call('outcome' => 'approved', 'user_feedback' => nil,
                                      'follow_up_issues' => body_params['follow_up_issues'])
    json_ok
  end

  post '/api/redirect' do
    body_params = JSON.parse(request.body.read) rescue {}
    c = control_for(body_params)
    return json_error(409, 'No pending approval') unless c&.pending_approval
    c.pending_approval[:resolve].call('outcome' => 'redirect',
                                      'user_feedback' => body_params['user_feedback'] || '',
                                      'follow_up_issues' => nil)
    json_ok
  end

  # Save global Synthup credentials (tenant + api_key only).
  post '/api/config' do
    body_params = JSON.parse(request.body.read) rescue {}
    tenant  = body_params['tenant'].to_s.strip
    api_key = body_params['api_key'].to_s.strip
    return json_error(400, 'tenant and api_key are required') if tenant.empty? || api_key.empty?
    Config.save_synthup_credentials(tenant: tenant, api_key: api_key)
    Synthup.api_key = api_key
    json_ok
  end

  # ── Projects ───────────────────────────────────────────────────────────────

  get '/api/projects' do
    content_type :json
    { projects: Projects.list.map(&:to_h),
      active_project_id: Config.load.active_project_id }.to_json
  end

  post '/api/projects' do
    body_params = JSON.parse(request.body.read) rescue {}
    url         = body_params['project_url'].to_s.strip
    github_repo = body_params['github_repo'].to_s.strip
    local_path  = body_params['local_path'].to_s.strip
    return json_error(400, 'project_url is required') if url.empty?
    project = Projects.create(
      project_url: url,
      github_repo: github_repo.empty? ? nil : github_repo,
      local_path:  local_path.empty? ? nil : local_path
    )
    # Set as the view default if none chosen yet — UI hint only.
    Config.set_active_project_id(project.id) if Config.load.active_project_id.to_s.empty?
    content_type :json
    project.to_h.to_json
  rescue ArgumentError => e
    json_error(400, e.message)
  end

  delete '/api/projects/:id' do |id|
    state = State.load(id)
    return json_error(409, 'Cannot delete a project while a task is running') if state && state['currentTask']
    cfg = Config.load
    Config.set_active_project_id(nil) if cfg.active_project_id == id
    Projects.delete(id)
    self.class.forget(id)
    json_ok
  end

  # Selects which project's panel the UI shows. All projects run in parallel,
  # so this no longer gates the orchestration loop.
  post '/api/projects/:id/activate' do |id|
    project = Projects.find(id)
    return json_error(404, 'Project not found') unless project
    Config.set_active_project_id(id)
    json_ok
  end

  post '/api/triage' do
    c = control_for_request
    return json_error(404, 'project_id required') unless c
    c.triage_requested = true
    json_ok
  end

  post '/api/resume-polling' do
    body_params = JSON.parse(request.body.read) rescue {}
    pid = resolve_project_id(body_params)
    return json_error(404, 'project_id required') unless pid
    state = State.load(pid)
    sid = state&.dig('escalation', 'resumable_task', 'session_id')
    return json_error(409, 'No resumable session on the current escalation') unless sid
    self.class.ctl(pid).resume_polling_requested = true
    json_ok
  end

  post '/api/cancel' do
    body_params = JSON.parse(request.body.read) rescue {}
    pid = resolve_project_id(body_params)
    return json_error(404, 'project_id required') unless pid
    c = self.class.ctl(pid)
    state = State.load(pid)
    ct = state&.dig('currentTask')
    return json_ok unless ct || c.pending_next_action

    c.pending_approval[:resolve].call('outcome' => 'cancelled') if c.pending_approval
    c.cancel_requested = true
    c.paused = false  # release any interactive gate
    json_ok
  end

  post '/api/pause' do
    c = control_for_request
    return json_error(404, 'project_id required') unless c
    c.paused = true
    json_ok
  end

  post '/api/resume' do
    c = control_for_request
    return json_error(404, 'project_id required') unless c
    c.paused = false
    json_ok
  end

  private

  def control_for_request
    body_params = JSON.parse(request.body.read) rescue {}
    control_for(body_params)
  end

  def control_for(body_params)
    pid = resolve_project_id(body_params)
    pid && self.class.ctl(pid)
  end

  def resolve_project_id(body_params)
    pid = body_params['project_id'].to_s.strip
    pid = Config.load.active_project_id if pid.empty?
    pid = pid.to_s.strip
    pid.empty? ? nil : pid
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
