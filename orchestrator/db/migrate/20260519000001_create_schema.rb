class CreateSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :config_entries, id: false do |t|
      t.string :key, primary_key: true
      t.text   :value
      t.timestamps null: false
    end

    create_table :projects, id: false do |t|
      t.string :id, primary_key: true
      t.string :project_url, null: false
      t.string :github_repo
      t.string :local_path
      t.timestamps null: false
    end

    create_table :project_states, id: false do |t|
      t.string  :project_id, primary_key: true
      t.integer :version, null: false, default: 2
      t.string  :status, null: false, default: 'running'
      t.text    :current_task
      t.text    :escalation
      t.timestamps null: false
    end
    add_foreign_key :project_states, :projects, column: :project_id, on_delete: :cascade

    create_table :project_history_entries do |t|
      t.string   :project_id, null: false
      t.string   :task, null: false
      t.string   :session_id
      t.datetime :completed_at, null: false
      t.integer  :duration_s
      t.text     :report
      t.timestamps null: false
    end
    add_index :project_history_entries, [:project_id, :completed_at]
    add_foreign_key :project_history_entries, :projects, column: :project_id, on_delete: :cascade
  end
end
