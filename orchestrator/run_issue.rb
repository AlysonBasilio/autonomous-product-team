# frozen_string_literal: true

# Returns a compact, human-readable summary of a routed action for UI display.
def describe_action(action)
  case action[:type]
  when 'run-task'
    ctx   = action[:context] || {}
    issue = ctx[:issue_id] ? " (issue #{ctx[:issue_id]})" : ''
    "run-task → #{action[:task]}#{issue}"
  when 'wait-approval'
    title = action.dig(:context, :issue_title) || action.dig(:context, :issue_id)
    "wait-approval → demo review#{title ? " for #{title}" : ''}"
  when 'escalate'
    "escalate → #{action[:reason]}"
  when 'done'
    'done'
  else
    action[:type].to_s
  end
end

# Dispatches a task as a Synthup session and polls for its report.
def dispatch_task(issue, cfg, task, context, control:)
  started_at  = Time.now.utc.iso8601
  task_path   = TaskRunner.find_task_file(task)
  model       = TaskRunner.parse_model(task_path)
  github_repo = issue.repo_url.to_s.sub(%r{https?://github\.com/}, '')
  prompt      = TaskRunner.compose_prompt(task_path, context || {})

  warn "[issue:#{issue.id}] dispatch #{task} model=#{model} repo=#{github_repo}"

  Issues.set_current_task(issue.id, {
    'task'       => task,
    'started_at' => started_at,
    'session_id' => nil
  })

  session = Synthup.create_session(
    tenant:  cfg.tenant,
    project: github_repo,
    prompt:  prompt,
    model:   model
  )

  warn "[issue:#{issue.id}] session created session=#{session['id'].to_s.slice(0, 8)}"

  Issues.set_current_task(issue.id, {
    'task'       => task,
    'session_id' => session['id'],
    'started_at' => started_at
  })
  issue.reload.update!(
    lifecycle_stage: Issues::STAGE_BY_TASK[task],
    last_session_id: session['id'],
    last_task:       task,
    last_event_at:   Time.now.utc,
    attempts:        (issue.reload.attempts || 0) + 1
  )

  report = TaskRunner.poll_for_report(session['id'],
             cancel_check: -> { control.cancel_requested },
             task_path:    task_path)
  Synthup.archive_session(session['id']) rescue nil
  warn "[issue:#{issue.id}] task #{task} complete report=#{report['type']} outcome=#{report['outcome']}"
  report
rescue TaskRunner::TimeoutError => e
  warn "[issue:#{issue.id}] task #{task} timeout: #{e.message}"
  { 'type' => 'task-failed', 'task' => task, 'details' => e.message }
rescue Synthup::Error => e
  warn "[issue:#{issue.id}] task #{task} Synthup error #{e.status}: #{e.body}"
  { 'type' => 'task-failed', 'task' => task,
    'details' => "Synthup API error #{e.status}: #{e.body}" }
end

# Translates a demo-review approval result into a demo-review-report the router
# can dispatch on.
def approval_to_report(approval, issue_id:, pr_url: nil)
  outcome = approval['outcome']
  return { 'type' => 'cancelled', 'outcome' => outcome } unless %w[approved redirect].include?(outcome)
  {
    'type'          => 'demo-review-report',
    'issue_id'      => issue_id,
    'pr_url'        => pr_url,
    'outcome'       => outcome,
    'user_feedback' => approval['user_feedback']
  }.compact
end

# Records a completed task into the issue's history JSON column.
def record_completed_task(issue, report, current_task_override: nil)
  current_task_snapshot = current_task_override || issue.reload.current_task
  started_at = current_task_snapshot&.dig('started_at')
  duration   = started_at ? (Time.now - Time.parse(started_at)).round : nil
  entry = {
    'task'         => current_task_snapshot&.dig('task'),
    'session_id'   => current_task_snapshot&.dig('session_id'),
    'completed_at' => Time.now.utc.iso8601,
    'duration_s'   => duration,
    'report'       => {
      'type'     => report['type'],
      'outcome'  => report['outcome'],
      'issue_id' => report['issue_id'],
      'pr_url'   => report['pr_url']
    }.compact
  }
  Issues.append_history(issue.id, entry)
  stage = stage_from_report(report)
  updates = { last_event_at: Time.now.utc }
  updates[:lifecycle_stage] = stage if stage
  updates[:last_pr_url]     = report['pr_url'] if report['pr_url']
  issue.reload.update!(updates)
  current_task_snapshot
end

def stage_from_report(report)
  case report['type']
  when 'task-complete'      then 'testing'
  when 'test-report'        then report['outcome'] == 'pass' ? 'reviewing' : 'coding'
  when 'demo-review-report' then report['outcome'] == 'approved' ? 'done' : 'coding'
  when 'discovery-complete' then 'done'
  end
end

# Drives one issue through code → test → demo-review until done or cancelled.
# Returns :done or :cancelled.
def run_issue_loop(issue_db_id, initial_action:, port:, interactive:, control:)
  action = initial_action

  warn "[issue:#{issue_db_id}] loop started action=#{describe_action(action)}"

  loop do
    if control.cancel_requested
      warn "[issue:#{issue_db_id}] cancel requested — stopping"
      return :cancelled
    end

    issue = Issue.find_by(id: issue_db_id)
    unless issue
      warn "[issue:#{issue_db_id}] not found in DB — stopping"
      return :cancelled
    end

    if control.paused
      warn "[issue:#{issue_db_id}] paused — waiting"
      loop { break unless control.paused; sleep 1 }
      warn "[issue:#{issue_db_id}] resumed"
    end

    cfg = Config.load
    unless cfg.synthup_configured?
      sleep 1
      next
    end
    Synthup.api_key = cfg.api_key

    warn "[issue:#{issue_db_id}] → #{describe_action(action)}"

    case action[:type]
    when 'resume-session'
      session_id = action[:session_id]
      task       = action[:task]
      warn "[issue:#{issue_db_id}] resuming session=#{session_id.to_s.slice(0, 8)} task=#{task}"
      task_path  = TaskRunner.find_task_file(task) rescue nil
      Synthup.send_message(session_id, prompt: TaskRunner.recovery_prompt(task_path)) rescue nil
      report = TaskRunner.poll_for_report(session_id,
                 cancel_check: -> { control.cancel_requested },
                 task_path:    task_path)
      Synthup.archive_session(session_id) rescue nil

      if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
        warn "[issue:#{issue_db_id}] cancelled during resume"
        control.cancel_requested = false
        Issues.clear_current_task(issue.id)
        return :cancelled
      end

      record_completed_task(issue, report)
      Issues.clear_current_task(issue.id)
      action = Router.route(report)
      warn "[issue:#{issue_db_id}] resume complete report=#{report['type']} → #{describe_action(action)}"
      next

    when 'run-task'
      ctx    = action[:context] || {}
      report = dispatch_task(issue, cfg, action[:task], ctx, control: control)

      if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
        warn "[issue:#{issue_db_id}] cancelled during task #{action[:task]}"
        control.cancel_requested = false
        Issues.clear_current_task(issue.id)
        return :cancelled
      end

      record_completed_task(issue, report)
      Issues.clear_current_task(issue.id)
      action = Router.route(report)
      warn "[issue:#{issue_db_id}] task #{action[:task]} routed → #{describe_action(action)}"
      next

    when 'wait-approval'
      ctx       = action[:context] || {}
      warn "[issue:#{issue_db_id}] waiting for demo-review approval pr=#{ctx[:pr_url]}"
      task_meta = {
        'task'        => 'demo-review.md',
        'phase'       => 'awaiting-approval',
        'started_at'  => Time.now.utc.iso8601,
        'pr_url'      => ctx[:pr_url],
        'issue_title' => ctx[:issue_title],
        'issue_id'    => ctx[:issue_id],
        'summary'     => ctx[:summary]
      }.compact
      Issues.set_current_task(issue.id, task_meta)
      approval = DemoReview.wait_for_approval(control: control, **ctx)
      report   = approval_to_report(approval, issue_id: ctx[:issue_id], pr_url: ctx[:pr_url])

      warn "[issue:#{issue_db_id}] approval outcome=#{approval['outcome']}"

      if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
        warn "[issue:#{issue_db_id}] cancelled during approval wait"
        control.cancel_requested = false
        Issues.clear_current_task(issue.id)
        return :cancelled
      end

      record_completed_task(issue, report, current_task_override: task_meta)
      Issues.clear_current_task(issue.id)
      action = Router.route(report)
      warn "[issue:#{issue_db_id}] approval complete → #{describe_action(action)}"
      next

    when 'escalate'
      warn "[issue:#{issue_db_id}] escalating reason=#{action[:reason]}"
      Issues.set_escalation(issue.id, {
        'reason'     => action[:reason],
        'details'    => action[:details],
        'session_id' => issue.reload.last_session_id,
        'timestamp'  => Time.now.utc.iso8601
      }.compact)
      Issues.clear_current_task(issue.id)
      warn "\n[#{issue_db_id}] escalated: #{action[:reason]}"
      warn action[:details].to_s
      puts "\n[#{issue_db_id}] UI: http://localhost:#{port} — resolve escalation to retry."
      # Block until escalation cleared or cancelled
      loop do
        sleep 2
        if control.cancel_requested
          warn "[issue:#{issue_db_id}] cancelled while escalated"
          return :cancelled
        end
        break unless issue.reload.escalation
      end
      # Check if dismissed (lifecycle_stage set to done by dismiss endpoint)
      if issue.reload.lifecycle_stage == 'done'
        warn "[issue:#{issue_db_id}] escalation dismissed — done"
        return :done
      end
      next_task = issue.last_task || 'code.md'
      warn "[issue:#{issue_db_id}] escalation resolved — retrying task=#{next_task}"
      ctx = { input_text: issue.input_text, pr_url: issue.last_pr_url, issue_id: issue.external_id }.compact
      action = { type: 'run-task', task: next_task, context: ctx }
      next

    when 'done', 'retriage'
      warn "[issue:#{issue_db_id}] #{action[:type]} — marking done"
      Issues.clear_current_task(issue.id)
      issue.reload.update!(lifecycle_stage: 'done')
      return :done

    when 'noop'
      warn "[issue:#{issue_db_id}] noop — stopping"
      Issues.clear_current_task(issue.id)
      return :done
    end
  end
rescue => e
  warn "[issue:#{issue_db_id}] loop crashed: #{e.class}: #{e.message}"
  warn e.backtrace.first(20).join("\n")
  Issues.clear_current_task(issue_db_id)
  :cancelled
end
