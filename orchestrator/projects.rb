require 'time'
require_relative 'db'
require_relative 'state'

# Project registry: deterministic slug per project_url, one Project row per slug.
module Projects
  GITHUB_REPO_RE = %r{\A(?:https?://(?:www\.)?github\.com/)?([^/\s]+/[^/\s]+?)(?:\.git)?/?\z}
  GITHUB_URL_RE  = %r{github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?(?:/|\z)}

  def self.id_for(url)
    s = url.to_s.strip.downcase
    s = s.sub(%r{\Ahttps?://}, '').sub(%r{\Awww\.}, '')
    s.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
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

  def self.list
    Project.order(:created_at).to_a
  end

  def self.find(id)
    return nil if id.to_s.strip.empty?
    Project.find_by(id: id)
  end

  # Creates a project (+ initial state row) if absent; otherwise patches changed
  # fields. Returns the Project either way.
  def self.create(project_url:, github_repo: nil, local_path: nil)
    raise ArgumentError, 'project_url is required' if project_url.to_s.strip.empty?
    id = id_for(project_url)
    raise ArgumentError, 'invalid project_url (could not derive id)' if id.empty?
    resolved_repo = resolve_github_repo(project_url: project_url, github_repo: github_repo)
    existing = Project.find_by(id: id)
    if existing
      patches = {}
      patches['local_path']  = local_path    if local_path && existing.local_path != local_path
      patches['github_repo'] = resolved_repo if existing.github_repo != resolved_repo
      State.patch(id, patches) unless patches.empty?
      return Project.find(id)
    end
    ActiveRecord::Base.transaction do
      project = Project.create!(
        id: id, project_url: project_url, github_repo: resolved_repo,
        local_path: local_path
      )
      ProjectState.create!(
        project_id: project.id, version: 2, status: 'running',
        current_task: nil, escalation: nil
      )
      project
    end
  end

  def self.delete(id)
    Project.find_by(id: id)&.destroy
  end
end
