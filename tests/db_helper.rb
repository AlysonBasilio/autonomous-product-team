# Shared test helper: points ActiveRecord at an in-memory SQLite database and
# runs migrations. Each test class calls `setup_in_memory_db` in `setup` and
# `teardown_in_memory_db` in `teardown` to get full isolation.

ENV['ORCHESTRATOR_DATA_DIR'] = ':memory:'

require_relative '../orchestrator/db'

module DBHelper
  def setup_in_memory_db
    ActiveRecord::Base.connection_pool.disconnect!
    DB.establish_connection
    silence_migration_output { DB.migrate! }
  end

  def teardown_in_memory_db
    ActiveRecord::Base.connection_pool.disconnect!
  end

  private

  def silence_migration_output
    prev = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    yield
  ensure
    ActiveRecord::Migration.verbose = prev
  end
end
