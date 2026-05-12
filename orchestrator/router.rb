module Router
  # Returns a NextAction hash:
  #   { type: "run-task", task: "plan.md", context: {} }
  #   { type: "wait-approval", context: {} }
  #   { type: "escalate", reason: "...", details: "..." }
  #   { type: "done" }
  def self.route(report, _current_state = {})
    case report['type']

    when 'triage-report'
      next_issue = report['next_issue']
      return { type: 'done' } unless next_issue
      issue_id = next_issue.is_a?(Hash) ? next_issue['id'] : next_issue
      run('plan.md', issue_id: issue_id)

    when 'plan-report'
      case report['next_task']
      when 'discovery'
        run('discovery.md', issue_id: report['issue_id'])
      when 'code'
        run('code.md',
            issue_id: report['issue_id'],
            branch:   report['branch'],
            plan:     report['plan'],
            findings: report['findings'],
            pr_url:   report['pr_url'])
      when 'test'
        run('test.md', issue_id: report['issue_id'], pr_url: report['pr_url'])
      when 'demo-review'
        run('demo-review.md', issue_id: report['issue_id'], pr_url: report['pr_url'])
      when 'create-issue'
        run('create-issue.md',
            issues:          report['issues'],
            source_issue_id: report['source_issue_id'] || report['issue_id'],
            split_context:   report['split_context'],
            return_to:       report['return_to'] || 'triage')
      else
        run('issue-triage.md')
      end

    when 'task-complete'
      follow_ups = report['follow_up_issues']
      if follow_ups && !follow_ups.empty?
        run('create-issue.md',
            issues:          follow_ups,
            source_issue_id: report['issue_id'],
            return_to:       'test',
            issue_id:        report['issue_id'],
            pr_url:          report['pr_url'])
      else
        run('test.md', issue_id: report['issue_id'], pr_url: report['pr_url'])
      end

    when 'test-report'
      run('plan.md',
          issue_id:     report['issue_id'],
          pr_url:       report['pr_url'],
          test_outcome: report['outcome'],
          findings:     report['findings'])

    when 'discovery-complete'
      run('issue-triage.md')

    when 'create-issue-complete'
      case report['return_to']
      when 'test'
        run('test.md', issue_id: report['source_issue_id'], pr_url: report['pr_url'])
      when 'plan'
        run('plan.md', issue_id: report['source_issue_id'])
      else
        run('issue-triage.md')
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
        follow_ups = report['follow_up_issues']
        if follow_ups && !follow_ups.empty?
          run('create-issue.md',
              issues:          follow_ups,
              source_issue_id: report['issue_id'],
              return_to:       'triage')
        else
          run('issue-triage.md')
        end
      else
        run('plan.md',
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
