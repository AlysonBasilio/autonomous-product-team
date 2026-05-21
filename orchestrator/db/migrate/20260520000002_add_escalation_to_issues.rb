# frozen_string_literal: true

class AddEscalationToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :escalation, :json
  end
end
