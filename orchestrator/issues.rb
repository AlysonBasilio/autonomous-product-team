require_relative 'db'

module Issues
  STAGE_BY_TASK = {
    'code.md'         => 'coding',
    'test.md'         => 'testing',
    'demo-review.md'  => 'reviewing',
    'discovery.md'    => 'discovery'
  }.freeze

  def self.set_current_task(issue_id, task_hash)
    issue = Issue.find_by(id: issue_id)
    return unless issue
    issue.current_task = task_hash
    issue.escalation   = nil
    issue.save!
    issue
  end

  def self.clear_current_task(issue_id)
    Issue.find_by(id: issue_id)&.update!(current_task: nil)
  end

  def self.set_escalation(issue_id, escalation_hash)
    Issue.find_by(id: issue_id)&.update!(escalation: escalation_hash)
  end

  def self.clear_escalation(issue_id)
    Issue.find_by(id: issue_id)&.update!(escalation: nil)
  end

  def self.append_history(issue_id, entry)
    issue = Issue.find_by(id: issue_id)
    return unless issue
    history = Array(issue.history) + [entry]
    issue.update!(history: history)
  end
end
