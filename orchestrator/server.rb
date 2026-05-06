require 'sinatra/base'
require 'json'
require_relative 'state'
require_relative 'synthup'

class OrchestratorServer < Sinatra::Base
  set :server, :puma
  set :logging, false

  CONFIG_KEYS = %w[project_url tenant api_key].freeze

  # Class-level state — shared across all per-request instances
  class << self
    attr_accessor :project_root, :paused, :pending_approval, :triage_requested, :cancel_requested, :pending_next_action
  end

  @paused              = false
  @triage_requested    = false
  @cancel_requested    = false
  @pending_approval    = nil
  @pending_next_action = nil

  def self.build_state_payload
    s = State.load(project_root) || State.initial
    approval_meta = pending_approval && {
      issue_title: pending_approval[:issue_title],
      issue_id:    pending_approval[:issue_id],
      pr_url:      pending_approval[:pr_url],
      summary:     pending_approval[:summary],
      kind:        pending_approval[:kind]
    }
    {
      status:              s['status'],
      paused:              paused,
      configured:          config_complete?(s['config']),
      config:              redacted_config(s['config']),
      currentTask:         s['currentTask'],
      history:             (s['history'] || []).last(20),
      escalation:          s['escalation'],
      pending_approval:    approval_meta,
      pending_next_action: pending_next_action
    }
  end

  def self.config_complete?(cfg)
    cfg.is_a?(Hash) && CONFIG_KEYS.all? { |k| cfg[k].to_s.strip != '' }
  end

  def self.redacted_config(cfg)
    return nil unless cfg.is_a?(Hash)
    cfg.merge('api_key' => cfg['api_key'] ? '••••' : nil)
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

  post '/api/config' do
    body_params = JSON.parse(request.body.read) rescue {}
    cfg = CONFIG_KEYS.each_with_object({}) { |k, h| h[k] = body_params[k].to_s.strip }
    return json_error(400, 'All fields are required') unless self.class.config_complete?(cfg)
    State.patch(self.class.project_root, 'config' => cfg)
    Synthup.api_key = cfg['api_key']
    json_ok
  end

  post '/api/triage' do
    self.class.triage_requested = true
    json_ok
  end

  post '/api/cancel' do
    state = State.load(self.class.project_root)
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
