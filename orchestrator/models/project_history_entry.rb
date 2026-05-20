class ProjectHistoryEntry < ActiveRecord::Base
  serialize :report, coder: JSON

  belongs_to :project, foreign_key: :project_id
end
