#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'socket'
require 'bundler/setup'

dir = File.dirname(__FILE__)
$LOAD_PATH.unshift(dir)

require_relative 'storage'
require_relative 'config'
require_relative 'projects'
require_relative 'synthup'
require_relative 'state'
require_relative 'router'
require_relative 'task_runner'
require_relative 'demo_review'
require_relative 'server'

# ── Start web server ──────────────────────────────────────────────────────────

port = (ENV['ORCHESTRATOR_PORT'] || 4242).to_i
interactive = ENV['ORCHESTRATOR_INTERACTIVE'] == '1'
server = OrchestratorServer

puts "Interactive mode: orchestrator will pause for approval before each action." if interactive

# Returns a compact, human-readable summary of a routed action for UI display.
def describe_action(action)
  case action[:type]
  when 'run-task'
    ctx     = action[:context] || {}
    issue   = ctx[:issue_id] ? " (issue #{ctx[:issue_id]})" : ''
    "run-task → #{action[:task]}#{issue}"
  when 'run-tasks-parallel'
    tasks = (action[:tasks] || []).map { |t| t[:task] }
    "run-tasks-parallel → #{tasks.join(', ')}"
  when 'wait-approval'
    title = action.dig(:context, :issue_title) || action.dig(:context, :issue_id)
    label = action.dig(:context, :kind) == 'test' ? 'user testing' : 'demo review'
    "wait-approval → #{label}#{title ? " for #{title}" : ''}"
  when 'escalate'
    "escalate → #{action[:reason]}"
  when 'done'
    'done — all issues complete'
  else
    action[:type].to_s
  end
end

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

# ── Wait for global config + an active project ───────────────────────────────

def wait_for_setup(port)
  cfg = Config.load
  needs_creds = !cfg.synthup_configured?
  needs_project = Projects.find(cfg.active_project_id).nil?
  return cfg unless needs_creds || needs_project

  puts "Waiting for setup at http://localhost:#{port} …"
  loop do
    sleep 1
    cfg = Config.load
    next unless cfg.synthup_configured?
    next if Projects.find(cfg.active_project_id).nil?
    return cfg
  end
end

cfg = wait_for_setup(port)
project = Projects.find(cfg.active_project_id)
Synthup.api_key = cfg.api_key

state = State.load(project.id)

if state['status'] == 'escalated'
  esc = state['escalation'] || {}
  warn "\nOrchestrator is in an escalated state and needs your attention."
  warn "Reason:  #{esc['reason']}"
  warn "Details: #{esc['details']}"
  puts "\nUI: http://localhost:#{port} — click 'Triage now' to reset and retry."
  loop { sleep 1; break if server.triage_requested }
  server.triage_requested = false
  state = State.patch(project.id, 'status' => 'running', 'escalation' => nil, 'currentTask' => nil)
end

if state['status'] == 'done'
  puts 'All issues are Done. Nothing to do.'
  puts "UI: http://localhost:#{port} — click 'Triage now' to start again."
  loop { sleep 1; break if server.triage_requested }
  server.triage_requested = false
  state = State.patch(project.id, 'status' => 'running', 'currentTask' => nil)
end

# ── Helpers ───────────────────────────────────────────────────────────────────

def dispatch_task(project, cfg, task, context)
  started_at = Time.now.utc.iso8601
  State.patch(project.id, 'currentTask' => {
    'task'       => task,
    'session_id' => nil,
    'started_at' => started_at,
    'context'    => context
  }, 'status' => 'running')

  task_path = TaskRunner.find_task_file(task)
  model     = TaskRunner.parse_model(task_path)
  full_context = { 'project_url' => project.project_url }.merge(context)
  prompt = TaskRunner.compose_prompt(task_path, full_context)

  session = Synthup.create_session(
    tenant:  cfg.tenant,
    project: github_repo(project.project_url),
    prompt:  prompt,
    model:   model
  )

  State.patch(project.id, 'currentTask' => {
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

# Translates an approval result from the wait-approval gate into a typed report
# the router can dispatch on. The `kind` field on the gate context selects the
# shape: 'test' produces a synthetic test-report; default produces demo-review-report.
def approval_to_report(approval, kind:, issue_id:, pr_url: nil)
  outcome = approval['outcome']
  if kind == 'test'
    case outcome
    when 'approved'
      { 'type' => 'test-report', 'outcome' => 'pass',
        'issue_id' => issue_id, 'pr_url' => pr_url, 'findings' => [] }.compact
    when 'redirect'
      feedback = approval['user_feedback'].to_s.strip
      findings = feedback.empty? ? [] : [{ 'description' => feedback, 'severity' => 'critical' }]
      { 'type' => 'test-report', 'outcome' => 'fail',
        'issue_id' => issue_id, 'pr_url' => pr_url, 'findings' => findings }.compact
    else  # timeout, cancelled, etc — surface as cancelled so the loop's cancel handling fires
      { 'type' => 'cancelled', 'outcome' => outcome }
    end
  else
    {
      'type'             => 'demo-review-report',
      'issue_id'         => issue_id,
      'outcome'          => outcome,
      'user_feedback'    => approval['user_feedback'],
      'follow_up_issues' => approval['follow_up_issues']
    }.compact
  end
end

# ── Main orchestration loop ───────────────────────────────────────────────────

trap('INT')  { puts "\nInterrupted."; exit 0 }
trap('TERM') { puts "\nTerminated.";  exit 0 }

pending_report = nil

loop do
  # Pause gate — check before every iteration
  loop { break unless server.paused; sleep 1 }

  # Refresh config + active project. Global config can change via UI mid-run.
  cfg = Config.load
  unless cfg.synthup_configured? && Projects.find(cfg.active_project_id)
    cfg = wait_for_setup(port)
  end
  Synthup.api_key = cfg.api_key

  # Detect active-project change: drop any pending report and resume cleanly.
  if project.id != cfg.active_project_id
    project = Projects.find(cfg.active_project_id)
    pending_report = nil
  end

  state = State.load(project.id)

  # Handle manual triage trigger
  if server.triage_requested
    server.triage_requested = false
    pending_report = nil
    state = State.patch(project.id, 'currentTask' => nil)
  end

  # Obtain a report for the current state
  report =
    if pending_report
      r = pending_report; pending_report = nil; r
    elsif state.dig('currentTask', 'task') == 'demo-review.md'
      ctx = state['currentTask']
      approval = DemoReview.wait_for_approval(
        server:      server,
        pr_url:      ctx['pr_url'],
        issue_title: ctx['issue_title'],
        issue_id:    ctx['issue_id'],
        summary:     ctx['summary'],
        kind:        ctx['kind']
      )
      approval_to_report(approval, kind: ctx['kind'], issue_id: ctx['issue_id'], pr_url: ctx['pr_url'])
    elsif (sid = state.dig('currentTask', 'session_id'))
      r = begin
        TaskRunner.poll_for_report(sid, cancel_check: -> { server.cancel_requested })
      rescue TaskRunner::TimeoutError => e
        { 'type' => 'task-failed', 'details' => e.message }
      end
      Synthup.archive_session(sid) rescue nil if r['type'] == 'cancelled'
      r
    else
      dispatch_task(project, cfg, 'issue-triage.md', {})
    end

  # Handle cancel
  if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
    State.clear_current_task(project.id)
    server.cancel_requested = false
    pending_report = nil
    next
  end

  # Record history (store only a compact summary of the report)
  # Reload state here so we capture the currentTask that was set by dispatch_task —
  # the local `state` variable may be stale if dispatch_task ran in the current iteration.
  current_task_state = State.load(project.id)
  started_at = current_task_state.dig('currentTask', 'started_at') ||
               state.dig('currentTask', 'started_at')
  duration   = started_at ? (Time.now - Time.parse(started_at)).round : nil
  State.record_history(project.id, {
    'task'         => current_task_state.dig('currentTask', 'task') || state.dig('currentTask', 'task'),
    'session_id'   => current_task_state.dig('currentTask', 'session_id') || state.dig('currentTask', 'session_id'),
    'completed_at' => Time.now.utc.iso8601,
    'duration_s'   => duration,
    'report'       => { 'type'     => report['type'],
                        'outcome'  => report['outcome'],
                        'issue_id' => report['issue_id'],
                        'pr_url'   => report['pr_url'] }.compact
  })
  State.clear_current_task(project.id)

  action = Router.route(report, state)

  if interactive && action[:type] != 'noop'
    server.pending_next_action = { type: action[:type], summary: describe_action(action) }
    server.paused = true
    loop { break unless server.paused; sleep 1 }
    server.pending_next_action = nil
    if server.cancel_requested
      server.cancel_requested = false
      next
    end
  end

  case action[:type]
  when 'run-task'
    new_report     = dispatch_task(project, cfg, action[:task], action[:context] || {})
    pending_report = new_report

  when 'run-tasks-parallel'
    threads = action[:tasks].map do |t|
      Thread.new { dispatch_task(project, cfg, t[:task], t[:context] || {}) }
    end
    reports        = threads.map(&:value)
    pending_report = reports.find { |r| r['type'] != 'create-issue-complete' } || reports.first

  when 'wait-approval'
    ctx = action[:context] || {}
    State.patch(project.id, 'currentTask' => {
      'task'        => 'demo-review.md',
      'session_id'  => nil,
      'started_at'  => Time.now.utc.iso8601,
      'pr_url'      => ctx[:pr_url],
      'issue_title' => ctx[:issue_title],
      'issue_id'    => ctx[:issue_id],
      'summary'     => ctx[:summary],
      'kind'        => ctx[:kind]
    }.compact)
    approval = DemoReview.wait_for_approval(server: server, **ctx)
    pending_report = approval_to_report(
      approval,
      kind:     ctx[:kind],
      issue_id: ctx[:issue_id],
      pr_url:   ctx[:pr_url]
    )

  when 'noop'
    # nothing — loop again to dispatch triage

  when 'escalate'
    State.patch(project.id, 'status' => 'escalated',
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
    State.patch(project.id, 'status' => 'running', 'escalation' => nil, 'currentTask' => nil)

  when 'done'
    State.patch(project.id, 'status' => 'done')
    puts "\nAll issues Done."
    puts "UI: http://localhost:#{port} — click 'Triage now' to start again."
    loop { sleep 1; break if server.triage_requested }
    server.triage_requested = false
    State.patch(project.id, 'status' => 'running', 'currentTask' => nil)
  end
end
