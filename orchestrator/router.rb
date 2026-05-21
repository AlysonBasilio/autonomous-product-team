module Router
  # Returns a NextAction hash:
  #   { type: "run-task", task: "code.md", context: {} }
  #   { type: "wait-approval", context: {} }
  #   { type: "escalate", reason: "...", details: "..." }
  #   { type: "done" }
  def self.route(report, _current_state = {})
    case report['type']

    when 'task-complete'
      run('test.md', issue_id: report['issue_id'], pr_url: report['pr_url'])

    when 'test-report'
      case report['outcome']
      when 'pass'
        run('demo-review.md', issue_id: report['issue_id'], pr_url: report['pr_url'])
      when 'fail'
        run('code.md',
            issue_id: report['issue_id'],
            pr_url:   report['pr_url'],
            findings: report['findings'])
      else
        { type: 'escalate',
          reason:  'blocked',
          details: report['details'] || "test-report outcome=#{report['outcome'].inspect}" }
      end

    when 'demo-review-pending'
      { type: 'wait-approval', context: {
        issue_id:    report['issue_id'],
        pr_url:      report['pr_url'],
        issue_title: report['issue_title'],
        summary:     report['summary']
      }.compact }

    when 'demo-review-report'
      if report['outcome'] == 'approved'
        { type: 'done' }
      else
        run('code.md',
            issue_id:      report['issue_id'],
            pr_url:        report['pr_url'],
            user_feedback: report['user_feedback'])
      end

    when 'task-failed'
      { type: 'escalate',
        reason:  'task-failed',
        details: report['details'] || report.to_json,
        task:    report['task'] }

    when 'blocked'
      { type: 'escalate',
        reason:  'blocked',
        details: report['what_is_blocked'] || report['details'] || report.to_json }

    when 'recovery-exhausted'
      { type: 'escalate',
        reason:  'recovery-exhausted',
        details: report['details'] || report.to_json }

    else
      { type: 'escalate',
        reason:  'unknown-report',
        details: "Unrecognised report type: #{report['type'].inspect}\n#{report.to_json}" }
    end
  end

  def self.run(task, **context)
    { type: 'run-task', task: task, context: context.compact }
  end
end
