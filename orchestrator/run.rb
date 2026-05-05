#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
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

# ── Startup checks ────────────────────────────────────────────────────────────

project_root = Dir.pwd
config_path  = File.join(project_root, 'product-team.config.json')

unless File.exist?(config_path)
  abort "config not found: #{config_path}\nRun: npx autonomous-product-team init"
end

config = JSON.parse(File.read(config_path))

unless ENV['SYNTHUP_API_KEY']
  abort 'Set the SYNTHUP_API_KEY environment variable before running the orchestrator.'
end

unless config['synthup_tenant']
  abort "synthup_tenant is not set in #{config_path}\nAdd: \"synthup_tenant\": \"<your-tenant-id>\""
end

unless config['project_url']
  abort "project_url is not set in #{config_path}"
end

# ── Start web server ──────────────────────────────────────────────────────────

port   = (ENV['ORCHESTRATOR_PORT'] || 4242).to_i
OrchestratorServer.project_root = project_root
server = OrchestratorServer  # class used as handle; state is class-level

Thread.new do
  OrchestratorServer.run!(port: port, bind: '127.0.0.1', quiet: true)
end

puts "Orchestrator UI: http://localhost:#{port}"
sleep 0.3 # let Puma bind before the first task

# ── Load or initialise state ──────────────────────────────────────────────────

state = State.load(project_root) || State.initial

if state['status'] == 'escalated'
  esc = state['escalation'] || {}
  warn "\nOrchestrator is in an escalated state and needs your attention."
  warn "Reason:  #{esc['reason']}"
  warn "Details: #{esc['details']}"
  puts "\nUI: http://localhost:#{port} — click 'Triage now' to reset and retry."
  loop { sleep 1; break if server.triage_requested }
  server.triage_requested = false
  state = State.patch(project_root, 'status' => 'running', 'escalation' => nil, 'currentTask' => nil)
  server.broadcast_state
end

if state['status'] == 'done'
  puts 'All issues are Done. Nothing to do.'
  puts "UI: http://localhost:#{port} — click 'Triage now' to start again."
  loop { sleep 1; break if server.triage_requested }
  server.triage_requested = false
  state = State.patch(project_root, 'status' => 'running', 'currentTask' => nil)
  server.broadcast_state
end

# ── Main orchestration loop ───────────────────────────────────────────────────

def main_loop(config, project_root, server, state)
  # Pause gate — check before every task dispatch
  loop { break unless server.paused; sleep 1 }

  # Handle manual triage trigger
  if server.triage_requested
    server.triage_requested = false
    state = State.patch(project_root, 'currentTask' => nil)
  end

  report =
    if state.dig('currentTask', 'task') == 'demo-review.md'
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
      dispatch_task(config, project_root, server, 'issue-triage.md', {}, state)
    end

  continue_from_report(config, project_root, server, State.load(project_root), report)
end

def dispatch_task(config, project_root, server, task, context, state)
  started_at = Time.now.utc.iso8601
  # Save intent before starting the session (crash-safe resume)
  State.patch(project_root, 'currentTask' => {
    'task'       => task,
    'session_id' => nil,
    'started_at' => started_at,
    'context'    => context
  }, 'status' => 'running')
  server.broadcast_state

  task_path = find_task_file(task, project_root)
  model     = TaskRunner.__send__(:parse_model, task_path)
  full_context = {
    'system'      => config['system'],
    'project_url' => config['project_url']
  }.merge(context)
  prompt    = TaskRunner.compose_prompt(task_path, full_context)

  session = Synthup.create_session(
    tenant:  config['synthup_tenant'],
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
  server.broadcast_state

  report = TaskRunner.poll_for_report(session['id'], cancel_check: -> { server.cancel_requested })
  Synthup.archive_session(session['id']) rescue nil
  report
rescue TaskRunner::TimeoutError => e
  { 'type' => 'task-failed', 'task' => task, 'details' => e.message }
rescue Synthup::Error => e
  { 'type' => 'task-failed', 'task' => task,
    'details' => "Synthup API error #{e.status}: #{e.body}" }
end

def continue_from_report(config, project_root, server, state, report)
  if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
    State.clear_current_task(project_root)
    server.cancel_requested = false
    server.broadcast_state
    main_loop(config, project_root, server, State.load(project_root))
    return
  end

  started_at = state.dig('currentTask', 'started_at')
  duration   = started_at ? (Time.now - Time.parse(started_at)).round : nil

  State.record_history(project_root, {
    'task'       => state.dig('currentTask', 'task'),
    'session_id' => state.dig('currentTask', 'session_id'),
    'completed_at' => Time.now.utc.iso8601,
    'duration_s' => duration,
    'report'     => report
  })
  State.clear_current_task(project_root)
  server.broadcast_state

  action = Router.route(report, state)

  case action[:type]
  when 'run-task'
    new_report = dispatch_task(config, project_root, server, action[:task], action[:context] || {}, state)
    current    = State.load(project_root)
    continue_from_report(config, project_root, server, current, new_report)

  when 'run-tasks-parallel'
    threads = action[:tasks].map do |t|
      Thread.new { dispatch_task(config, project_root, server, t[:task], t[:context] || {}, state) }
    end
    reports = threads.map(&:value)
    primary = reports.find { |r| r['type'] != 'create-issue-complete' } || reports.first
    current = State.load(project_root)
    continue_from_report(config, project_root, server, current, primary)

  when 'wait-approval'
    ctx = action[:context] || {}
    State.patch(project_root, 'currentTask' => {
      'task'       => 'demo-review.md',
      'session_id' => nil,
      'started_at' => Time.now.utc.iso8601,
      'pr_url'     => ctx[:pr_url],
      'issue_title'=> ctx[:issue_title],
      'issue_id'   => ctx[:issue_id],
      'summary'    => ctx[:summary]
    })
    server.broadcast_state

    approval = DemoReview.wait_for_approval(server: server, **ctx)
    demo_report = {
      'type'             => 'demo-review-report',
      'issue_id'         => ctx[:issue_id],
      'outcome'          => approval['outcome'],
      'user_feedback'    => approval['user_feedback'],
      'follow_up_issues' => approval['follow_up_issues']
    }.compact

    current = State.load(project_root)
    continue_from_report(config, project_root, server, current, demo_report)

  when 'noop'
    current = State.load(project_root)
    main_loop(config, project_root, server, current)

  when 'escalate'
    State.patch(project_root, {
      'status'     => 'escalated',
      'escalation' => {
        'reason'    => action[:reason],
        'details'   => action[:details],
        'timestamp' => Time.now.utc.iso8601
      }
    })
    server.broadcast_state
    warn "\nOrchestrator escalated: #{action[:reason]}"
    warn action[:details]
    puts "\nUI: http://localhost:#{ENV.fetch('ORCHESTRATOR_PORT', 4242)} — click 'Triage now' to retry."
    loop { sleep 1; break if server.triage_requested }
    server.triage_requested = false
    State.patch(project_root, 'status' => 'running', 'escalation' => nil, 'currentTask' => nil)
    server.broadcast_state
    main_loop(config, project_root, server, State.load(project_root))

  when 'done'
    State.patch(project_root, 'status' => 'done')
    server.broadcast_state
    puts "\nAll issues Done."
    puts "\nUI: http://localhost:#{ENV.fetch('ORCHESTRATOR_PORT', 4242)} — click 'Triage now' to start again."
    loop { sleep 1; break if server.triage_requested }
    server.triage_requested = false
    State.patch(project_root, 'status' => 'running', 'currentTask' => nil)
    server.broadcast_state
    main_loop(config, project_root, server, State.load(project_root))
  end
end

def github_repo(url)
  url.match(%r{github\.com/([^/]+/[^/]+)})&.then { |m| m[1].sub(/\.git$/, '') } || url
end

def find_task_file(task, project_root)
  path = File.join(project_root, 'tasks', task)
  raise "Task file not found: #{task}" unless File.exist?(path)
  path
end

# ── Start ─────────────────────────────────────────────────────────────────────

trap('INT')  { puts "\nInterrupted."; exit 0 }
trap('TERM') { puts "\nTerminated.";  exit 0 }

main_loop(config, project_root, server, state)
