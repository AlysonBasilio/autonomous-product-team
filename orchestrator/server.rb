require 'sinatra/base'
require 'json'
require 'thread'
require_relative 'state'

class OrchestratorServer < Sinatra::Base
  set :server, :puma
  set :logging, false

  # Class-level state — shared across all per-request instances
  class << self
    attr_accessor :project_root, :paused, :pending_approval, :triage_requested, :cancel_requested
    attr_reader   :sse_clients, :sse_mutex
  end

  @paused            = false
  @triage_requested  = false
  @cancel_requested  = false
  @pending_approval  = nil
  @sse_clients       = []
  @sse_mutex         = Mutex.new

  def self.broadcast_state
    data = build_state_payload.to_json
    @sse_mutex.synchronize do
      @sse_clients.each { |q| q << data rescue nil }
      @sse_clients.reject!(&:closed?) rescue nil
    end
  end

  def self.build_state_payload
    s = State.load(project_root) || State.initial
    approval_meta = pending_approval && {
      issue_title: pending_approval[:issue_title],
      issue_id:    pending_approval[:issue_id],
      pr_url:      pending_approval[:pr_url],
      summary:     pending_approval[:summary]
    }
    {
      status:           s['status'],
      paused:           paused,
      currentTask:      s['currentTask'],
      history:          (s['history'] || []).last(20),
      escalation:       s['escalation'],
      pending_approval: approval_meta
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

  get '/api/events' do
    content_type 'text/event-stream'
    cache_control 'no-cache'
    headers 'X-Accel-Buffering' => 'no'

    queue = Queue.new
    self.class.sse_mutex.synchronize { self.class.sse_clients << queue }

    stream(:keep_open) do |out|
      out << "data: #{self.class.build_state_payload.to_json}\n\n"
      loop do
        data = queue.pop
        break if data == :close
        out << "data: #{data}\n\n"
      rescue
        break
      end
      self.class.sse_mutex.synchronize { self.class.sse_clients.delete(queue) }
    end
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

  post '/api/triage' do
    self.class.triage_requested = true
    self.class.broadcast_state
    json_ok
  end

  post '/api/cancel' do
    state = State.load(self.class.project_root)
    ct = state&.dig('currentTask')
    return json_ok unless ct

    pa = self.class.pending_approval
    pa[:resolve].call('outcome' => 'cancelled') if pa

    self.class.cancel_requested = true
    self.class.broadcast_state
    json_ok
  end

  post '/api/pause' do
    self.class.paused = true
    self.class.broadcast_state
    json_ok
  end

  post '/api/resume' do
    self.class.paused = false
    self.class.broadcast_state
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
