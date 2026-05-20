class CreateIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :issues, id: false do |t|
      t.string   :id, primary_key: true
      t.string   :source, null: false, default: 'linear'
      t.string   :external_id, null: false
      t.string   :project_id
      t.string   :title
      t.string   :status
      t.integer  :priority
      t.string   :url
      t.datetime :last_synced_at
      t.string   :lifecycle_stage
      t.integer  :attempts, null: false, default: 0
      t.string   :last_session_id
      t.string   :last_pr_url
      t.string   :last_task
      t.datetime :last_event_at
      t.timestamps null: false
    end
    add_index :issues, [:source, :external_id], unique: true
    add_index :issues, :project_id
    add_foreign_key :issues, :projects, column: :project_id, on_delete: :nullify
  end
end
