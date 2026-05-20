# frozen_string_literal: true

require_relative 'run_issue'

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

  ctx_issue_id = context[:issue_id] || context['issue_id']
  if ctx_issue_id
    Issues.upsert(
      external_id: ctx_issue_id,
      project_id:  project.id,
      ops: {
        lifecycle_stage: Issues::STAGE_BY_TASK[task],
        last_session_id: session['id'],
        last_task:       task,
        last_event_at:   Time.now.utc,
        attempt_delta:   1
      }
    )
  end

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

# Puts the project into 'escalated' state, logs to stdout, and blocks until the
# user clicks "Triage now" or "Resume polling". Returns true if the user chose
# to resume polling an existing session (when resumable_task is present).
def handle_escalation(project_id, action, current_task_snapshot, port:, control:)
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
    return nil unless Projects.find(project_id)
    break if control.triage_requested || (resumable_task && control.resume_polling_requested)
  end
  resume = resumable_task && control.resume_polling_requested
  control.resume_polling_requested = false
  control.triage_requested = false
  State.patch(project_id, 'status' => 'running', 'escalation' => nil,
    'currentTask' => resume ? resumable_task : nil)
  resume
end

# Records a completed task into project history and updates issue tracking.
def record_completed_task(project_id, report, state)
  current_task_state    = State.load(project_id)
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
  Issues.record_event(project_id, report, current_task: current_task_snapshot)
  State.clear_current_task(project_id)
  current_task_snapshot
end

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
      state = State.patch(project_id, 'currentTask' => nil)
    end

    # Run triage — either resume a pending session or start fresh.
    report =
      if (sid = state.dig('currentTask', 'session_id'))
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

    # Handle cancel during triage.
    if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
      State.clear_current_task(project_id)
      control.cancel_requested = false
      next
    end

    current_task_snapshot = record_completed_task(project_id, report, state)

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
      issue_id = action.dig(:context, :issue_id)
      run_issue_loop(project_id, issue_id, initial_action: action,
                     port: port, interactive: interactive, control: control)

    when 'escalate'
      result = handle_escalation(project_id, action, current_task_snapshot, port: port, control: control)
      return unless result # project deleted

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
