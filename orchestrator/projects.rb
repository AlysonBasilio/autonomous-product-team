require 'time'
require_relative 'storage'
require_relative 'state'

# Project registry: deterministic slug per project_url, per-project state files.
module Projects
  PROJECTS_DIR = 'projects'

  Project = Struct.new(:id, :project_url, :local_path, :created_at, keyword_init: true) do
    def to_h
      { 'id' => id, 'project_url' => project_url,
        'local_path' => local_path, 'created_at' => created_at }
    end
  end

  def self.id_for(url)
    s = url.to_s.strip.downcase
    s = s.sub(%r{\Ahttps?://}, '').sub(%r{\Awww\.}, '')
    s = s.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
    s
  end

  def self.path_for(id)
    File.join(PROJECTS_DIR, "#{id}.json")
  end

  def self.list
    Storage.default.list(PROJECTS_DIR).filter_map do |fname|
      next unless fname.end_with?('.json')
      data = Storage.default.read_json(File.join(PROJECTS_DIR, fname))
      next unless data
      Project.new(
        id:          data['id'],
        project_url: data['project_url'],
        local_path:  data['local_path'],
        created_at:  data['created_at']
      )
    end
  end

  def self.find(id)
    return nil if id.to_s.strip.empty?
    data = Storage.default.read_json(path_for(id))
    return nil unless data
    Project.new(
      id:          data['id'],
      project_url: data['project_url'],
      local_path:  data['local_path'],
      created_at:  data['created_at']
    )
  end

  # Creates a project state file if absent, returns the project either way.
  def self.create(project_url:, local_path: nil)
    raise ArgumentError, 'project_url is required' if project_url.to_s.strip.empty?
    id = id_for(project_url)
    raise ArgumentError, 'invalid project_url (could not derive id)' if id.empty?
    if Storage.default.exist?(path_for(id))
      existing = Storage.default.read_json(path_for(id))
      State.patch(id, 'local_path' => local_path) if local_path && existing['local_path'] != local_path
      return find(id)
    end
    initial = State.initial(id: id, project_url: project_url, local_path: local_path)
    Storage.default.write_json(path_for(id), initial)
    Project.new(
      id: id, project_url: project_url, local_path: local_path,
      created_at: initial['created_at']
    )
  end

  def self.delete(id)
    Storage.default.delete(path_for(id))
  end
end
