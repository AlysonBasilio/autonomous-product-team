class ProjectState < ActiveRecord::Base
  self.primary_key = :project_id

  serialize :current_task, coder: JSON
  serialize :escalation,   coder: JSON

  belongs_to :project, foreign_key: :project_id
end
