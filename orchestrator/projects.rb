require 'time'
require_relative 'storage'
require_relative 'state'

# Project registry: deterministic slug per project_url, per-project state files.
module Projects
  PROJECTS_DIR = 'projects'

  Project = Struct.new(:id, :project_url, :github_repo, :local_path, :created_at, keyword_init: true) do
    def to_h
      { 'id' => id, 'project_url' => project_url, 'github_repo' => github_repo,
        'local_path' => local_path, 'created_at' => created_at }
    end
  end

  GITHUB_REPO_RE = %r{\A(?:https?://(?:www\.)?github\.com/)?([^/\s]+/[^/\s]+?)(?:\.git)?/?\z}
  GITHUB_URL_RE  = %r{github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?(?:/|\z)}

  def self.id_for(url)
    s = url.to_s.strip.downcase
    s = s.sub(%r{\Ahttps?://}, '').sub(%r{\Awww\.}, '')
    s = s.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
    s
  end

  def self.path_for(id)
    File.join(PROJECTS_DIR, "#{id}.json")
  end

  # Resolves a github_repo (owner/repo) for a project. Explicit input wins;
  # otherwise extracts from a GitHub project_url; otherwise raises.
  def self.resolve_github_repo(project_url:, github_repo:)
    if github_repo && !github_repo.to_s.strip.empty?
      m = github_repo.to_s.strip.match(GITHUB_REPO_RE)
      raise ArgumentError, "github_repo must be 'owner/repo' or a github.com URL" unless m
      return m[1]
    end
    m = project_url.to_s.match(GITHUB_URL_RE)
    return m[1] if m
    raise ArgumentError, 'github_repo is required when project_url is not a GitHub URL'
  end

  # Lazy back-fill for legacy records: derive github_repo from project_url
  # when the stored record predates this field.
  def self.backfill_github_repo(data)
    return data['github_repo'] if data['github_repo']
    m = data['project_url'].to_s.match(GITHUB_URL_RE)
    m ? m[1] : nil
  end

  def self.list
    Storage.default.list(PROJECTS_DIR).filter_map do |fname|
      next unless fname.end_with?('.json')
      data = Storage.default.read_json(File.join(PROJECTS_DIR, fname))
      next unless data
      Project.new(
        id:          data['id'],
        project_url: data['project_url'],
        github_repo: backfill_github_repo(data),
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
      github_repo: backfill_github_repo(data),
      local_path:  data['local_path'],
      created_at:  data['created_at']
    )
  end

  # Creates a project state file if absent, returns the project either way.
  def self.create(project_url:, github_repo: nil, local_path: nil)
    raise ArgumentError, 'project_url is required' if project_url.to_s.strip.empty?
    id = id_for(project_url)
    raise ArgumentError, 'invalid project_url (could not derive id)' if id.empty?
    resolved_repo = resolve_github_repo(project_url: project_url, github_repo: github_repo)
    if Storage.default.exist?(path_for(id))
      existing = Storage.default.read_json(path_for(id))
      patches = {}
      patches['local_path']  = local_path  if local_path && existing['local_path'] != local_path
      patches['github_repo'] = resolved_repo if existing['github_repo'] != resolved_repo
      State.patch(id, patches) unless patches.empty?
      return find(id)
    end
    initial = State.initial(id: id, project_url: project_url,
                            github_repo: resolved_repo, local_path: local_path)
    Storage.default.write_json(path_for(id), initial)
    Project.new(
      id: id, project_url: project_url, github_repo: resolved_repo,
      local_path: local_path, created_at: initial['created_at']
    )
  end

  def self.delete(id)
    Storage.default.delete(path_for(id))
  end
end
