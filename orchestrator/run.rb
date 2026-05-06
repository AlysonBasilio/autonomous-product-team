#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'socket'
ENV['BUNDLE_GEMFILE'] ||= File.join(File.dirname(__FILE__), 'Gemfile')
require 'bundler/setup'

dir = File.dirname(__FILE__)
$LOAD_PATH.unshift(dir)

require_relative 'synthup'
require_relative 'state'
require_relative 'router'
require_relative 'task_runner'
require_relative 'demo_review'
require_relative 'server'

# ── Start web server ──────────────────────────────────────────────────────────

project_root = Dir.pwd
port   = (ENV['ORCHESTRATOR_PORT'] || 4242).to_i
OrchestratorServer.project_root = project_root
server = OrchestratorServer  # class used as handle; state is class-level

Thread.new do
  OrchestratorServer.run!(port: port, bind: '127.0.0.1', quiet: true)
end

puts "Orchestrator UI: http://localhost:#{port}"

# Wait for Puma to accept connections before dispatching the first task
20.times do
  Socket.tcp('127.0.0.1', port, connect_timeout: 0.1) { break }
rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
  sleep 0.1
end

# ── Load or initialise state ──────────────────────────────────────────────────

state = State.load(project_root) || State.initial

# ── Wait for configuration via UI ─────────────────────────────────────────────

unless OrchestratorServer.config_complete?(state['config'])
  puts "Waiting for configuration at http://localhost:#{port} …"
  until OrchestratorServer.config_complete?(state['config'])
    sleep 1
    state = State.load(project_root) || State.initial
  end
end

config = state['config']
Synthup.api_key = config['api_key']

if state['status'] == 'escalated'
  esc = state['escalation'] || {}
  warn "\nOrchestrator is in an escalated state and needs your attention."
  warn "Reason:  #{esc['reason']}"
  warn "Details: #{esc['details']}"
  puts "\nUI: http://localhost:#{port} — click 'Triage now' to reset and retry."
  loop { sleep 1; break if server.triage_requested }
  server.triage_requested = false
  state = State.patch(project_root, 'status' => 'running', 'escalation' => nil, 'currentTask' => nil)
end

if state['status'] == 'done'
  puts 'All issues are Done. Nothing to do.'
  puts "UI: http://localhost:#{port} — click 'Triage now' to start again."
  loop { sleep 1; break if server.triage_requested }
  server.triage_requested = false
  state = State.patch(project_root, 'status' => 'running', 'currentTask' => nil)
end

# ── Helpers ───────────────────────────────────────────────────────────────────

def dispatch_task(config, project_root, task, context)
  started_at = Time.now.utc.iso8601
  State.patch(project_root, 'currentTask' => {
    'task'       => task,
    'session_id' => nil,
    'started_at' => started_at,
    'context'    => context
  }, 'status' => 'running')

  task_path = TaskRunner.find_task_file(task, project_root)
  model     = TaskRunner.parse_model(task_path)
  full_context = { 'project_url' => config['project_url'] }.merge(context)
  prompt = TaskRunner.compose_prompt(task_path, full_context)

  session = Synthup.create_session(
    tenant:  config['tenant'],
    project: github_repo(config['project_url']),
    prompt:  prompt,
    model:   model
  )

  State.patch(project_root, 'currentTask' => {
    'task'       => task,
    'session_id' => session['id'],
    'started_at' => started_at,
    'context'    => context
  })

  report = TaskRunner.poll_for_report(session['id'])
  Synthup.archive_session(session['id']) rescue nil
  report
rescue TaskRunner::TimeoutError => e
  { 'type' => 'task-failed', 'task' => task, 'details' => e.message }
rescue Synthup::Error => e
  { 'type' => 'task-failed', 'task' => task,
    'details' => "Synthup API error #{e.status}: #{e.body}" }
end

def github_repo(url)
  url.match(%r{github\.com/([^/]+/[^/]+)})&.then { |m| m[1].sub(/\.git$/, '') } || url
end

# ── Main orchestration loop ───────────────────────────────────────────────────

trap('INT')  { puts "\nInterrupted."; exit 0 }
trap('TERM') { puts "\nTerminated.";  exit 0 }

pending_report = nil

loop do
  # Pause gate — check before every iteration
  loop { break unless server.paused; sleep 1 }

  state = State.load(project_root)

  # Handle manual triage trigger
  if server.triage_requested
    server.triage_requested = false
    pending_report = nil
    state = State.patch(project_root, 'currentTask' => nil)
  end

  # Obtain a report for the current state
  report =
    if pending_report
      r = pending_report; pending_report = nil; r
    elsif state.dig('currentTask', 'task') == 'demo-review.md'
      ctx = state['currentTask']
      DemoReview.wait_for_approval(
        server:      server,
        pr_url:      ctx['pr_url'],
        issue_title: ctx['issue_title'],
        issue_id:    ctx['issue_id'],
        summary:     ctx['summary']
      )
    elsif (sid = state.dig('currentTask', 'session_id'))
      r = begin
        TaskRunner.poll_for_report(sid, cancel_check: -> { server.cancel_requested })
      rescue TaskRunner::TimeoutError => e
        { 'type' => 'task-failed', 'details' => e.message }
      end
      Synthup.archive_session(sid) rescue nil if r['type'] == 'cancelled'
      r
    else
      dispatch_task(config, project_root, 'issue-triage.md', {})
    end

  # Handle cancel
  if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
    State.clear_current_task(project_root)
    server.cancel_requested = false
    pending_report = nil
    next
  end

  # Record history (store only a compact summary of the report)
  # Reload state here so we capture the currentTask that was set by dispatch_task —
  # the local `state` variable may be stale if dispatch_task ran in the current iteration.
  current_task_state = State.load(project_root)
  started_at = current_task_state.dig('currentTask', 'started_at') ||
               state.dig('currentTask', 'started_at')
  duration   = started_at ? (Time.now - Time.parse(started_at)).round : nil
  State.record_history(project_root, {
    'task'         => current_task_state.dig('currentTask', 'task') || state.dig('currentTask', 'task'),
    'session_id'   => current_task_state.dig('currentTask', 'session_id') || state.dig('currentTask', 'session_id'),
    'completed_at' => Time.now.utc.iso8601,
    'duration_s'   => duration,
    'report'       => { 'type'     => report['type'],
                        'outcome'  => report['outcome'],
                        'issue_id' => report['issue_id'],
                        'pr_url'   => report['pr_url'] }.compact
  })
  State.clear_current_task(project_root)

  action = Router.route(report, state)

  case action[:type]
  when 'run-task'
    new_report     = dispatch_task(config, project_root, action[:task], action[:context] || {})
    pending_report = new_report

  when 'run-tasks-parallel'
    threads = action[:tasks].map do |t|
      Thread.new { dispatch_task(config, project_root, t[:task], t[:context] || {}) }
    end
    reports        = threads.map(&:value)
    pending_report = reports.find { |r| r['type'] != 'create-issue-complete' } || reports.first

  when 'wait-approval'
    ctx = action[:context] || {}
    State.patch(project_root, 'currentTask' => {
      'task'        => 'demo-review.md',
      'session_id'  => nil,
      'started_at'  => Time.now.utc.iso8601,
      'pr_url'      => ctx[:pr_url],
      'issue_title' => ctx[:issue_title],
      'issue_id'    => ctx[:issue_id],
      'summary'     => ctx[:summary]
    })
    approval = DemoReview.wait_for_approval(server: server, **ctx)
    pending_report = {
      'type'             => 'demo-review-report',
      'issue_id'         => ctx[:issue_id],
      'outcome'          => approval['outcome'],
      'user_feedback'    => approval['user_feedback'],
      'follow_up_issues' => approval['follow_up_issues']
    }.compact

  when 'noop'
    # nothing — loop again to dispatch triage

  when 'escalate'
    State.patch(project_root, 'status' => 'escalated',
      'escalation' => {
        'reason'    => action[:reason],
        'details'   => action[:details],
        'timestamp' => Time.now.utc.iso8601
      })
    warn "\nOrchestrator escalated: #{action[:reason]}"
    warn action[:details]
    puts "\nUI: http://localhost:#{port} — click 'Triage now' to retry."
    loop { sleep 1; break if server.triage_requested }
    server.triage_requested = false
    State.patch(project_root, 'status' => 'running', 'escalation' => nil, 'currentTask' => nil)

  when 'done'
    State.patch(project_root, 'status' => 'done')
    puts "\nAll issues Done."
    puts "UI: http://localhost:#{port} — click 'Triage now' to start again."
    loop { sleep 1; break if server.triage_requested }
    server.triage_requested = false
    State.patch(project_root, 'status' => 'running', 'currentTask' => nil)
  end
end
