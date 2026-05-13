require 'json'
require 'time'
require_relative 'storage'

# Per-project state. Persisted as data/projects/<id>.json via Storage.default.
module State
  HISTORY_CAP = 100

  def self.initial(id:, project_url:, github_repo: nil, local_path: nil)
    {
      'version'     => 2,
      'id'          => id,
      'project_url' => project_url,
      'github_repo' => github_repo,
      'local_path'  => local_path,
      'created_at'  => Time.now.utc.iso8601,
      'status'      => 'running',
      'currentTask'               => nil,
      'escalation'               => nil,
      'current_issue_id'          => nil,
      'current_issue_title'       => nil,
      'current_issue_description' => nil,
      'history'                   => []
    }
  end

  def self.path_for(project_id)
    File.join('projects', "#{project_id}.json")
  end

  def self.load(project_id)
    return nil if project_id.to_s.strip.empty?
    Storage.default.read_json(path_for(project_id))
  end

  def self.save(project_id, state)
    Storage.default.write_json(path_for(project_id), state)
  end

  def self.patch(project_id, hash)
    Storage.default.update_json(path_for(project_id)) do |state|
      raise "State for project #{project_id} not found" if state.empty?
      state.merge(hash)
    end
  end

  def self.clear_current_task(project_id)
    patch(project_id, 'currentTask' => nil)
  end

  def self.record_history(project_id, entry)
    Storage.default.update_json(path_for(project_id)) do |state|
      raise "State for project #{project_id} not found" if state.empty?
      history = (state['history'] || []) + [entry]
      state.merge('history' => history.last(HISTORY_CAP))
    end
  end
end
