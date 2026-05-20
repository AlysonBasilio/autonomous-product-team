require_relative 'db'

module Issues
  STAGE_BY_TASK = {
    'issue-triage.md' => 'triaged',
    'code.md'         => 'coding',
    'test.md'         => 'testing',
    'demo-review.md'  => 'reviewing',
    'discovery.md'    => 'discovery',
    'create-issue.md' => nil
  }.freeze

  CACHE_KEYS = %i[title status priority url].freeze
  OPS_KEYS   = %i[lifecycle_stage last_session_id last_pr_url last_task last_event_at].freeze

  def self.upsert(external_id:, source: 'linear', project_id: nil, cache: {}, ops: {})
    return nil if external_id.to_s.strip.empty?

    row = Issue.find_or_initialize_by(source: source, external_id: external_id)
    row.project_id ||= project_id if project_id

    cache_attrs = symbolize(cache).slice(*CACHE_KEYS).compact
    unless cache_attrs.empty?
      row.assign_attributes(cache_attrs)
      row.last_synced_at = Time.now.utc
    end

    ops_sym = symbolize(ops)
    row.assign_attributes(ops_sym.slice(*OPS_KEYS).compact)
    if ops_sym[:attempt_delta]
      row.attempts = (row.attempts || 0) + ops_sym[:attempt_delta].to_i
    end

    row.save!
    row
  end

  def self.record_event(project_id, report, current_task: nil)
    return nil unless report.is_a?(Hash)

    external_id, cache = extract_issue(report)
    return nil unless external_id

    upsert(
      external_id: external_id,
      project_id:  project_id,
      cache:       cache,
      ops: {
        lifecycle_stage: stage_from(report, current_task),
        last_session_id: current_task && current_task['session_id'],
        last_pr_url:     report['pr_url'],
        last_task:       current_task && current_task['task'],
        last_event_at:   Time.now.utc
      }
    )
  end

  def self.extract_issue(report)
    if report['type'] == 'triage-report' && report['next_issue'].is_a?(Hash)
      ni = report['next_issue']
      [ni['id'], {
        title:    ni['title'],
        status:   ni['status'],
        priority: ni['priority'],
        url:      ni['url']
      }]
    else
      id = report['issue_id']
      id ||= report['next_issue'] if report['next_issue'].is_a?(String)
      [id, { title: report['issue_title'] }]
    end
  end

  def self.stage_from(report, current_task)
    case report['type']
    when 'triage-report'      then 'triaged'
    when 'task-complete'      then 'testing'
    when 'test-report'        then report['outcome'] == 'pass' ? 'reviewing' : 'coding'
    when 'demo-review-report' then report['outcome'] == 'approved' ? 'done' : 'coding'
    when 'discovery-complete' then 'triaged'
    else
      task = current_task && current_task['task']
      STAGE_BY_TASK[task]
    end
  end

  def self.symbolize(hash)
    return {} unless hash.is_a?(Hash)
    hash.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
  end
end
