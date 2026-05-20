class Project < ActiveRecord::Base
  self.primary_key = :id

  has_one  :state, class_name: 'ProjectState', foreign_key: :project_id, dependent: :destroy
  has_many :history_entries, -> { order(:completed_at) },
           class_name: 'ProjectHistoryEntry', foreign_key: :project_id, dependent: :destroy

  def to_h
    { 'id' => id, 'project_url' => project_url, 'github_repo' => github_repo,
      'local_path' => local_path, 'created_at' => created_at&.iso8601 }
  end
end
