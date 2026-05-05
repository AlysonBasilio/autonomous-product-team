module Router
  KNOWN_REPORT_TYPES = %w[
    triage-report plan-report task-complete split-report test-report
    demo-review-pending demo-review-report discovery-complete
    create-issue-complete status-correction-report
    qa-blocked-missing-env-setup task-failed blocked
  ].freeze

  # Returns a NextAction hash:
  #   { type: "run-task", task: "plan.md", context: {} }
  #   { type: "run-tasks-parallel", tasks: [{task:, context:}, ...] }
  #   { type: "wait-approval", context: {} }
  #   { type: "escalate", reason: "...", details: "..." }
  #   { type: "done" }
  def self.route(report, current_state = {})
    type = report['type']

    case type

    when 'triage-report'
      next_issue = report['next_issue']
      return { type: 'done' } unless next_issue

      issue_type = report['issue_type']
      task = issue_type == 'discovery' ? 'discovery.md' : 'plan.md'
      { type: 'run-task', task: task, context: { issue_id: next_issue } }

    when 'plan-report'
      next_task = report['next_task']
      case next_task
      when 'code'
        { type: 'run-task', task: 'code.md', context: {
          issue_id:  report['issue_id'],
          branch:    report['branch'],
          plan:      report['plan'],
          findings:  report['findings']
        }.compact }
      when 'test'
        { type: 'run-task', task: 'test.md', context: {
          issue_id: report['issue_id'],
          pr_url:   report['pr_url']
        }.compact }
      when 'demo-review'
        { type: 'run-task', task: 'demo-review.md', context: {
          issue_id: report['issue_id'],
          pr_url:   report['pr_url']
        }.compact }
      else
        { type: 'run-task', task: 'issue-triage.md', context: {} }
      end

    when 'split-report'
      { type: 'run-task', task: 'create-issue.md', context: {
        issues:       report['issues'],
        split_context: true
      } }

    when 'create-issue-complete'
      if report['split_context']
        { type: 'run-task', task: 'issue-triage.md', context: {} }
      else
        { type: 'noop' }
      end

    when 'task-complete'
      follow_ups = report['follow_up_issues']
      if follow_ups && !follow_ups.empty?
        { type: 'run-tasks-parallel', tasks: [
          { task: 'create-issue.md', context: { issues: follow_ups } },
          { task: 'test.md', context: { issue_id: report['issue_id'], pr_url: report['pr_url'] } }
        ]}
      else
        { type: 'run-task', task: 'test.md', context: {
          issue_id: report['issue_id'],
          pr_url:   report['pr_url']
        }.compact }
      end

    when 'qa-blocked-missing-env-setup'
      { type: 'run-task', task: 'create-issue.md', context: {
        title:       'Missing environment setup documentation',
        description: report['details']
      }.compact }

    when 'discovery-complete'
      { type: 'run-task', task: 'issue-triage.md', context: {} }

    when 'test-report'
      outcome = report['outcome']
      if outcome == 'pass'
        { type: 'run-task', task: 'demo-review.md', context: {
          issue_id: report['issue_id'],
          pr_url:   report['pr_url']
        }.compact }
      else
        { type: 'run-task', task: 'code.md', context: {
          issue_id: report['issue_id'],
          pr_url:   report['pr_url'],
          findings: report['findings']
        }.compact }
      end

    when 'demo-review-pending'
      { type: 'wait-approval', context: {
        issue_id:    report['issue_id'],
        pr_url:      report['pr_url'],
        issue_title: report['issue_title'],
        summary:     report['summary']
      }.compact }

    when 'demo-review-report'
      outcome = report['outcome']
      if outcome == 'approved'
        follow_ups = report['follow_up_issues']
        if follow_ups && !follow_ups.empty?
          { type: 'run-tasks-parallel', tasks: [
            { task: 'create-issue.md', context: { issues: follow_ups } },
            { task: 'issue-triage.md', context: {} }
          ]}
        else
          { type: 'run-task', task: 'issue-triage.md', context: {} }
        end
      else
        { type: 'run-task', task: 'code.md', context: {
          issue_id:     report['issue_id'],
          pr_url:       report['pr_url'],
          user_feedback: report['user_feedback']
        }.compact }
      end

    when 'status-correction-report'
      now_unblocked = report['now_unblocked']
      if now_unblocked && !now_unblocked.empty?
        { type: 'run-task', task: 'issue-triage.md', context: {} }
      else
        { type: 'done' }
      end

    when 'task-failed'
      { type: 'escalate',
        reason:  'task-failed',
        details: report['details'] || report.to_json,
        task:    report['task'] }

    when 'blocked'
      { type: 'escalate',
        reason:  'blocked',
        details: report['what_is_blocked'] || report.to_json }

    else
      { type: 'escalate',
        reason:  'unknown-report',
        details: "Unrecognised report type: #{type.inspect}\n#{report.to_json}" }
    end
  end
end
