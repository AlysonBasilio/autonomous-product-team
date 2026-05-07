require 'sinatra/base'
require 'json'
require_relative 'state'
require_relative 'config'
require_relative 'projects'
require_relative 'synthup'

class OrchestratorServer < Sinatra::Base
  set :server, :puma
  set :logging, false

  # Class-level state — shared across all per-request instances
  class << self
    attr_accessor :paused, :pending_approval, :triage_requested, :cancel_requested, :pending_next_action
  end

  @paused              = false
  @triage_requested    = false
  @cancel_requested    = false
  @pending_approval    = nil
  @pending_next_action = nil

  def self.build_state_payload
    cfg     = Config.load
    project = Projects.find(cfg.active_project_id)
    s       = project ? (State.load(project.id) || {}) : {}

    approval_meta = pending_approval && {
      issue_title: pending_approval[:issue_title],
      issue_id:    pending_approval[:issue_id],
      pr_url:      pending_approval[:pr_url],
      summary:     pending_approval[:summary],
      kind:        pending_approval[:kind]
    }

    {
      synthup_configured:  cfg.synthup_configured?,
      synthup:             { tenant: cfg.tenant,
                             tenant_from_env: Config.tenant_from_env?,
                             api_key_from_env: Config.api_key_from_env? },
      projects:            Projects.list.map(&:to_h),
      active_project_id:   cfg.active_project_id,
      status:              s['status'],
      paused:              paused,
      currentTask:         s['currentTask'],
      history:             (s['history'] || []).last(20),
      escalation:          s['escalation'],
      pending_approval:    approval_meta,
      pending_next_action: pending_next_action
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
    pa = self.class.pending_approval
    return json_error(409, 'No pending approval') unless pa
    body_params = JSON.parse(request.body.read) rescue {}
    pa[:resolve].call('outcome' => 'approved', 'user_feedback' => nil,
                      'follow_up_issues' => body_params['follow_up_issues'])
    json_ok
  end

  post '/api/redirect' do
    pa = self.class.pending_approval
    return json_error(409, 'No pending approval') unless pa
    body_params = JSON.parse(request.body.read) rescue {}
    pa[:resolve].call('outcome' => 'redirect',
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
    # Activate immediately if there's no active project yet.
    Config.set_active_project_id(project.id) if Config.load.active_project_id.to_s.empty?
    content_type :json
    project.to_h.to_json
  rescue ArgumentError => e
    json_error(400, e.message)
  end

  delete '/api/projects/:id' do |id|
    cfg = Config.load
    if cfg.active_project_id == id
      state = State.load(id)
      return json_error(409, 'Cannot delete the active project while a task is running') if state && state['currentTask']
      Config.set_active_project_id(nil)
    end
    Projects.delete(id)
    json_ok
  end

  post '/api/projects/:id/activate' do |id|
    project = Projects.find(id)
    return json_error(404, 'Project not found') unless project
    cfg = Config.load
    if cfg.active_project_id && cfg.active_project_id != id
      active_state = State.load(cfg.active_project_id)
      return json_error(409, 'Cannot switch projects while a task is running') if active_state && active_state['currentTask']
    end
    Config.set_active_project_id(id)
    json_ok
  end

  post '/api/triage' do
    self.class.triage_requested = true
    json_ok
  end

  post '/api/cancel' do
    cfg = Config.load
    state = cfg.active_project_id ? State.load(cfg.active_project_id) : nil
    ct = state&.dig('currentTask')
    return json_ok unless ct || self.class.pending_next_action

    pa = self.class.pending_approval
    pa[:resolve].call('outcome' => 'cancelled') if pa

    self.class.cancel_requested = true
    self.class.paused = false  # release any interactive gate
    json_ok
  end

  post '/api/pause' do
    self.class.paused = true
    json_ok
  end

  post '/api/resume' do
    self.class.paused = false
    json_ok
  end

  private

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
