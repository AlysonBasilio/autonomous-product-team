class SimplifyToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :input_text, :text
    add_column :issues, :repo_url,   :string
    add_column :issues, :history,    :json

    # external_id was NOT NULL for Linear issues; now issues may have no Linear id
    remove_index  :issues, [:source, :external_id]
    change_column :issues, :external_id, :string, null: true
    add_index     :issues, [:source, :external_id],
                  unique: true, where: 'external_id IS NOT NULL'

    remove_foreign_key :issues, :projects
    remove_column :issues, :project_id

    drop_table :project_history_entries
    drop_table :project_states
    drop_table :projects
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
