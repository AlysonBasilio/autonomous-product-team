require 'json'
require 'fileutils'

# Storage abstraction for persisting JSON documents under a single data root.
# A future SQLite implementation can satisfy the same interface.
module Storage
  class JsonFileStorage
    def initialize(root)
      @root = root
      @mutexes = {}
      @mutexes_guard = Mutex.new
    end

    def read_json(rel)
      path = absolute(rel)
      return nil unless File.exist?(path)
      JSON.parse(File.read(path))
    end

    def write_json(rel, hash)
      path = absolute(rel)
      mutex_for(rel).synchronize do
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp"
        File.write(tmp, JSON.pretty_generate(hash))
        File.rename(tmp, path)
      end
      hash
    end

    def update_json(rel)
      mutex_for(rel).synchronize do
        current = read_json(rel) || {}
        updated = yield(current)
        path = absolute(rel)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp"
        File.write(tmp, JSON.pretty_generate(updated))
        File.rename(tmp, path)
        updated
      end
    end

    def list(rel_dir)
      dir = absolute(rel_dir)
      return [] unless Dir.exist?(dir)
      Dir.children(dir).sort
    end

    def delete(rel)
      path = absolute(rel)
      mutex_for(rel).synchronize do
        File.delete(path) if File.exist?(path)
      end
    end

    def exist?(rel)
      File.exist?(absolute(rel))
    end

    private

    def absolute(rel)
      File.join(@root, rel)
    end

    def mutex_for(rel)
      @mutexes_guard.synchronize { @mutexes[rel] ||= Mutex.new }
    end
  end

  def self.default
    @default ||= JsonFileStorage.new(
      File.expand_path(ENV.fetch('ORCHESTRATOR_DATA_DIR', 'data'),
                       File.expand_path('..', __dir__))
    )
  end

  # Test hook: replace the default storage instance.
  def self.default=(impl)
    @default = impl
  end
end
