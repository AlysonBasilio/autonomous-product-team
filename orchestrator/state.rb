require 'json'
require 'fileutils'

module State
  STATE_FILE  = 'orchestrator-state.json'
  HISTORY_CAP = 100
  MUTEX       = Mutex.new

  def self.initial
    {
      'version'    => 1,
      'status'     => 'running',
      'currentTask'=> nil,
      'escalation' => nil,
      'history'    => []
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
    MUTEX.synchronize do
      state = load(project_root) || initial
      state.merge!(hash)
      save(project_root, state)
      state
    end
  end

  def self.clear_current_task(project_root)
    patch(project_root, 'currentTask' => nil)
  end

  def self.record_history(project_root, entry)
    MUTEX.synchronize do
      state   = load(project_root) || initial
      history = state['history'] || []
      history << entry
      state['history'] = history.last(HISTORY_CAP)
      save(project_root, state)
      state
    end
  end
end
