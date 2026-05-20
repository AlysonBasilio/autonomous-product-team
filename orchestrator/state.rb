require 'time'
require_relative 'db'

# Per-project state. The runtime shape (a hash mirroring the legacy JSON
# document) is reconstructed from `Project` + `ProjectState` + the last
# HISTORY_CAP `ProjectHistoryEntry` rows.
module State
  HISTORY_CAP = 100
  PROJECT_FIELDS = %w[github_repo local_path project_url].freeze
  STATE_FIELDS   = %w[status current_task escalation version].freeze

  def self.initial(id:, project_url:, github_repo: nil, local_path: nil)
    {
      'version'     => 2,
      'id'          => id,
      'project_url' => project_url,
      'github_repo' => github_repo,
      'local_path'  => local_path,
      'created_at'  => Time.now.utc.iso8601,
      'status'      => 'running',
      'currentTask' => nil,
      'escalation'  => nil,
      'history'     => []
    }
  end

  def self.load(project_id)
    return nil if project_id.to_s.strip.empty?
    project = Project.find_by(id: project_id)
    return nil unless project
    s = project.state || ProjectState.new(project_id: project.id)
    history = ProjectHistoryEntry
              .where(project_id: project.id)
              .order(:completed_at)
              .last(HISTORY_CAP)
              .map { |e| serialize_history(e) }
    {
      'version'     => s.version || 2,
      'id'          => project.id,
      'project_url' => project.project_url,
      'github_repo' => project.github_repo,
      'local_path'  => project.local_path,
      'created_at'  => project.created_at&.iso8601,
      'status'      => s.status || 'running',
      'currentTask' => s.current_task,
      'escalation'  => s.escalation,
      'history'     => history
    }
  end

  def self.patch(project_id, hash)
    project = Project.find_by(id: project_id)
    raise "State for project #{project_id} not found" unless project
    ActiveRecord::Base.transaction do
      project_attrs = {}
      state_attrs   = {}
      hash.each do |k, v|
        key = k.to_s
        case key
        when 'currentTask' then state_attrs[:current_task] = v
        when 'status', 'escalation', 'version'
          state_attrs[key.to_sym] = v
        when 'github_repo', 'local_path', 'project_url'
          project_attrs[key.to_sym] = v
        else
          raise ArgumentError, "Unknown state field: #{key}"
        end
      end
      project.update!(project_attrs) unless project_attrs.empty?
      unless state_attrs.empty?
        s = project.state || project.build_state
        s.assign_attributes(state_attrs)
        s.save!
      end
    end
    load(project_id)
  end

  def self.clear_current_task(project_id)
    patch(project_id, 'currentTask' => nil)
  end

  def self.record_history(project_id, entry)
    raise "State for project #{project_id} not found" unless Project.exists?(id: project_id)
    ActiveRecord::Base.transaction do
      ProjectHistoryEntry.create!(
        project_id:   project_id,
        task:         entry['task'],
        session_id:   entry['session_id'],
        completed_at: parse_time(entry['completed_at']) || Time.now.utc,
        duration_s:   entry['duration_s'],
        report:       entry['report']
      )
      trim_history(project_id)
    end
    load(project_id)
  end

  def self.trim_history(project_id)
    keep_ids = ProjectHistoryEntry
               .where(project_id: project_id)
               .order(completed_at: :desc)
               .limit(HISTORY_CAP)
               .pluck(:id)
    ProjectHistoryEntry.where(project_id: project_id).where.not(id: keep_ids).delete_all
  end

  def self.serialize_history(entry)
    {
      'task'         => entry.task,
      'session_id'   => entry.session_id,
      'completed_at' => entry.completed_at&.iso8601,
      'duration_s'   => entry.duration_s,
      'report'       => entry.report
    }
  end

  def self.parse_time(value)
    return nil if value.nil?
    return value if value.is_a?(Time)
    Time.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
