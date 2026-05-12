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

puts "Interactive mode: orchestrator will pause for approval before each action." if interactive

# Returns a compact, human-readable summary of a routed action for UI display.
def describe_action(action)
  case action[:type]
  when 'run-task'
    ctx     = action[:context] || {}
    issue   = ctx[:issue_id] ? " (issue #{ctx[:issue_id]})" : ''
    "run-task → #{action[:task]}#{issue}"
  when 'wait-approval'
    title = action.dig(:context, :issue_title) || action.dig(:context, :issue_id)
    "wait-approval → demo review#{title ? " for #{title}" : ''}"
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

# ── Wait for global config + at least one project ────────────────────────────

def wait_for_setup(port)
  cfg = Config.load
  return cfg if cfg.synthup_configured? && Projects.list.any?

  puts "Waiting for setup at http://localhost:#{port} …"
  loop do
    sleep 1
    cfg = Config.load
    next unless cfg.synthup_configured?
    next if Projects.list.empty?
    return cfg
  end
end

cfg = wait_for_setup(port)
Synthup.api_key = cfg.api_key

# ── Helpers ───────────────────────────────────────────────────────────────────

def dispatch_task(project, cfg, task, context, control:)
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

  unless project.github_repo
    return { 'type' => 'task-failed', 'task' => task,
             'details' => 'project missing github_repo — recreate via the UI with a GitHub repo URL or explicit github_repo' }
  end

  session = Synthup.create_session(
    tenant:  cfg.tenant,
    project: project.github_repo,
    prompt:  prompt,
    model:   model
  )

  State.patch(project.id, 'currentTask' => {
    'task'       => task,
    'session_id' => session['id'],
    'started_at' => started_at,
    'context'    => context
  })

  report = TaskRunner.poll_for_report(session['id'], cancel_check: -> { control.cancel_requested }, task_path: task_path)
  Synthup.archive_session(session['id']) rescue nil
  report
rescue TaskRunner::TimeoutError => e
  { 'type' => 'task-failed', 'task' => task, 'details' => e.message }
rescue Synthup::Error => e
  { 'type' => 'task-failed', 'task' => task,
    'details' => "Synthup API error #{e.status}: #{e.body}" }
end

# Translates a demo-review approval result from the wait-approval gate into a
# demo-review-report the router can dispatch on. Timeouts/cancellations are
# surfaced as 'cancelled' so the loop's cancel handling fires.
def approval_to_report(approval, issue_id:, pr_url: nil)
  outcome = approval['outcome']
  return { 'type' => 'cancelled', 'outcome' => outcome } unless %w[approved redirect].include?(outcome)
  {
    'type'             => 'demo-review-report',
    'issue_id'         => issue_id,
    'pr_url'           => pr_url,
    'outcome'          => outcome,
    'user_feedback'    => approval['user_feedback'],
    'follow_up_issues' => approval['follow_up_issues']
  }.compact
end

# ── Per-project orchestration loop ────────────────────────────────────────────

def run_project_loop(project_id, port:, interactive:)
  control = OrchestratorServer.ctl(project_id)

  project = Projects.find(project_id)
  return unless project

  state = State.load(project_id) || {}

  if state['status'] == 'escalated'
    esc = state['escalation'] || {}
    resumable_task = esc['resumable_task']
    warn "\n[#{project_id}] escalated and needs your attention."
    warn "[#{project_id}] Reason:  #{esc['reason']}"
    warn "[#{project_id}] Details: #{esc['details']}"
    hint = resumable_task ? "click 'Triage now' to reset, or 'Resume polling' to keep watching the existing session" : "click 'Triage now' to reset and retry"
    puts "\n[#{project_id}] UI: http://localhost:#{port} — #{hint}."
    loop do
      sleep 1
      return unless Projects.find(project_id)
      break if control.triage_requested || (resumable_task && control.resume_polling_requested)
    end
    resume = resumable_task && control.resume_polling_requested
    control.resume_polling_requested = false
    control.triage_requested = false
    state = State.patch(project_id, 'status' => 'running', 'escalation' => nil,
      'currentTask' => resume ? resumable_task : nil)
  end

  if state['status'] == 'done'
    puts "[#{project_id}] All issues are Done. Nothing to do."
    puts "[#{project_id}] UI: http://localhost:#{port} — click 'Triage now' to start again."
    loop do
      sleep 1
      return unless Projects.find(project_id)
      break if control.triage_requested
    end
    control.triage_requested = false
    state = State.patch(project_id, 'status' => 'running', 'currentTask' => nil)
  end

  pending_report = nil

  loop do
    # Project was deleted — stop the loop cleanly.
    project = Projects.find(project_id)
    return unless project

    # Pause gate — check before every iteration
    loop { break unless control.paused; sleep 1 }

    # Refresh global config (creds can change via UI).
    cfg = Config.load
    unless cfg.synthup_configured?
      sleep 1
      next
    end
    Synthup.api_key = cfg.api_key

    state = State.load(project_id) || {}

    # Handle manual triage trigger
    if control.triage_requested
      control.triage_requested = false
      pending_report = nil
      state = State.patch(project_id, 'currentTask' => nil)
    end

    # Obtain a report for the current state
    report =
      if pending_report
        r = pending_report; pending_report = nil; r
      elsif state.dig('currentTask', 'task') == 'demo-review.md'
        ctx = state['currentTask']
        approval = DemoReview.wait_for_approval(
          control:     control,
          pr_url:      ctx['pr_url'],
          issue_title: ctx['issue_title'],
          issue_id:    ctx['issue_id'],
          summary:     ctx['summary']
        )
        approval_to_report(approval, issue_id: ctx['issue_id'], pr_url: ctx['pr_url'])
      elsif (sid = state.dig('currentTask', 'session_id'))
        task_name = state.dig('currentTask', 'task')
        task_path = task_name ? (TaskRunner.find_task_file(task_name) rescue nil) : nil
        r = begin
          TaskRunner.poll_for_report(sid, cancel_check: -> { control.cancel_requested }, task_path: task_path)
        rescue TaskRunner::TimeoutError => e
          { 'type' => 'task-failed', 'details' => e.message }
        end
        Synthup.archive_session(sid) rescue nil
        r
      else
        dispatch_task(project, cfg, 'issue-triage.md', {}, control: control)
      end

    # Handle cancel
    if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
      State.clear_current_task(project_id)
      control.cancel_requested = false
      pending_report = nil
      next
    end

    # Record history (store only a compact summary of the report)
    # Reload state here so we capture the currentTask that was set by dispatch_task —
    # the local `state` variable may be stale if dispatch_task ran in the current iteration.
    current_task_state = State.load(project_id)
    current_task_snapshot = current_task_state['currentTask'] || state['currentTask']
    started_at = current_task_snapshot&.dig('started_at')
    duration   = started_at ? (Time.now - Time.parse(started_at)).round : nil
    State.record_history(project_id, {
      'task'         => current_task_snapshot&.dig('task'),
      'session_id'   => current_task_snapshot&.dig('session_id'),
      'completed_at' => Time.now.utc.iso8601,
      'duration_s'   => duration,
      'report'       => { 'type'     => report['type'],
                          'outcome'  => report['outcome'],
                          'issue_id' => report['issue_id'],
                          'pr_url'   => report['pr_url'] }.compact
    })
    State.clear_current_task(project_id)

    action = Router.route(report, state)

    if interactive && action[:type] != 'noop'
      control.pending_next_action = { type: action[:type], summary: describe_action(action) }
      control.paused = true
      loop { break unless control.paused; sleep 1 }
      control.pending_next_action = nil
      if control.cancel_requested
        control.cancel_requested = false
        next
      end
    end

    case action[:type]
    when 'run-task'
      new_report     = dispatch_task(project, cfg, action[:task], action[:context] || {}, control: control)
      pending_report = new_report

    when 'wait-approval'
      ctx = action[:context] || {}
      State.patch(project_id, 'currentTask' => {
        'task'        => 'demo-review.md',
        'session_id'  => nil,
        'started_at'  => Time.now.utc.iso8601,
        'pr_url'      => ctx[:pr_url],
        'issue_title' => ctx[:issue_title],
        'issue_id'    => ctx[:issue_id],
        'summary'     => ctx[:summary]
      }.compact)
      approval = DemoReview.wait_for_approval(control: control, **ctx)
      pending_report = approval_to_report(
        approval,
        issue_id: ctx[:issue_id],
        pr_url:   ctx[:pr_url]
      )

    when 'escalate'
      resumable_task = (action[:reason] == 'recovery-exhausted' &&
                        current_task_snapshot&.dig('session_id')) ? current_task_snapshot : nil
      State.patch(project_id, 'status' => 'escalated',
        'escalation' => {
          'reason'         => action[:reason],
          'details'        => action[:details],
          'resumable_task' => resumable_task,
          'timestamp'      => Time.now.utc.iso8601
        }.compact)
      warn "\n[#{project_id}] escalated: #{action[:reason]}"
      warn action[:details]
      hint = resumable_task ? "click 'Triage now' to retry, or 'Resume polling' to keep watching the existing session" : "click 'Triage now' to retry"
      puts "\n[#{project_id}] UI: http://localhost:#{port} — #{hint}."
      loop do
        sleep 1
        return unless Projects.find(project_id)
        break if control.triage_requested || (resumable_task && control.resume_polling_requested)
      end
      resume = resumable_task && control.resume_polling_requested
      control.resume_polling_requested = false
      control.triage_requested = false
      State.patch(project_id, 'status' => 'running', 'escalation' => nil,
        'currentTask' => resume ? resumable_task : nil)

    when 'done'
      State.patch(project_id, 'status' => 'done')
      puts "\n[#{project_id}] All issues Done."
      puts "[#{project_id}] UI: http://localhost:#{port} — click 'Triage now' to start again."
      loop do
        sleep 1
        return unless Projects.find(project_id)
        break if control.triage_requested
      end
      control.triage_requested = false
      State.patch(project_id, 'status' => 'running', 'currentTask' => nil)
    end
  end
rescue => e
  warn "[#{project_id}] loop crashed: #{e.class}: #{e.message}"
  warn e.backtrace.first(20).join("\n")
end

# ── Supervisor: one orchestration thread per project ─────────────────────────

trap('INT')  { puts "\nInterrupted."; exit 0 }
trap('TERM') { puts "\nTerminated.";  exit 0 }

threads = {}  # project_id => Thread

loop do
  ids = Projects.list.map(&:id)

  # Spawn threads for newly added projects
  ids.each do |id|
    next if threads[id] && threads[id].alive?
    threads[id] = Thread.new { run_project_loop(id, port: port, interactive: interactive) }
    puts "[supervisor] started loop for #{id}"
  end

  # Reap dead/finished threads so they get re-spawned if the project still exists
  threads.each_pair do |id, t|
    next if t.alive?
    t.join rescue nil
    threads.delete(id)
  end

  sleep 3
end
