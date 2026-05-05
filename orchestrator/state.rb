require 'json'
require 'fileutils'

module State
  STATE_FILE = 'orchestrator-state.json'
  HISTORY_CAP = 100

  def self.initial
    {
      'version'               => 1,
      'status'                => 'running',
      'currentTask'           => nil,
      'pending_parallel_tasks'=> [],
      'last_report'           => nil,
      'escalation'            => nil,
      'history'               => []
    }
  end

  def self.load(project_root)
    path = File.join(project_root, STATE_FILE)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  end

  def self.save(project_root, state)
    path = File.join(project_root, STATE_FILE)
    tmp  = "#{path}.tmp"
    FileUtils.mkdir_p(File.dirname(path))
    File.write(tmp, JSON.pretty_generate(state))
    File.rename(tmp, path)
  end

  def self.patch(project_root, hash)
    state = load(project_root) || initial
    state.merge!(hash)
    save(project_root, state)
    state
  end

  def self.clear_current_task(project_root)
    patch(project_root, 'currentTask' => nil)
  end

  def self.record_history(project_root, entry)
    state = load(project_root) || initial
    history = state['history'] || []
    history << entry
    history = history.last(HISTORY_CAP)
    state['history'] = history
    save(project_root, state)
    state
  end
end
