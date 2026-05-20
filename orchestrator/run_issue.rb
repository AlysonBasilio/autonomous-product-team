# frozen_string_literal: true

# Drives one issue through code → test → demo-review until it is done,
# escalated, or cancelled. Called synchronously from run_project_loop after
# triage picks an issue; returns :done, :cancelled, or :escalated_and_reset.
def run_issue_loop(project_id, issue_id, initial_action:, port:, interactive:, control:)
  action = initial_action

  loop do
    return :cancelled if control.cancel_requested

    project = Projects.find(project_id)
    return :cancelled unless project

    loop { break unless control.paused; sleep 1 }

    cfg = Config.load
    unless cfg.synthup_configured?
      sleep 1
      next
    end
    Synthup.api_key = cfg.api_key

    state = State.load(project_id) || {}

    if interactive && action[:type] != 'noop'
      control.pending_next_action = { type: action[:type], summary: describe_action(action) }
      control.paused = true
      loop { break unless control.paused; sleep 1 }
      control.pending_next_action = nil
      if control.cancel_requested
        control.cancel_requested = false
        Issues.clear_current_task(issue_id)
        return :cancelled
      end
    end

    case action[:type]
    when 'run-task'
      ctx    = action[:context] || {}
      Issues.set_current_task(issue_id, { 'task' => action[:task], 'started_at' => Time.now.utc.iso8601 })
      report = dispatch_task(project, cfg, action[:task], ctx, control: control)

      if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
        control.cancel_requested = false
        Issues.clear_current_task(issue_id)
        return :cancelled
      end

      record_completed_task(project_id, report, state)
      Issues.clear_current_task(issue_id)

      action = Router.route(report, state)
      next

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
      Issues.set_current_task(issue_id, { 'task' => 'demo-review.md', 'started_at' => Time.now.utc.iso8601 })
      approval = DemoReview.wait_for_approval(control: control, **ctx)
      report   = approval_to_report(approval, issue_id: ctx[:issue_id], pr_url: ctx[:pr_url])

      if report['type'] == 'cancelled' || report['outcome'] == 'cancelled'
        control.cancel_requested = false
        Issues.clear_current_task(issue_id)
        State.clear_current_task(project_id)
        return :cancelled
      end

      record_completed_task(project_id, report, state)
      Issues.clear_current_task(issue_id)

      action = Router.route(report, state)
      next

    when 'escalate'
      result = handle_escalation(project_id, action, nil, port: port, control: control)
      return :escalated_and_reset if result.nil? # project deleted
      Issues.clear_current_task(issue_id)
      return :escalated_and_reset

    when 'done'
      Issues.clear_current_task(issue_id)
      return :done
    end
  end
rescue => e
  warn "[#{project_id}/#{issue_id}] issue loop crashed: #{e.class}: #{e.message}"
  warn e.backtrace.first(20).join("\n")
  :escalated_and_reset
end
