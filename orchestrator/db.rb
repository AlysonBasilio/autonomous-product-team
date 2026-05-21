require 'active_record'
require 'sqlite3'
require 'fileutils'
require 'logger'

module DB
  MIGRATIONS_PATH = File.expand_path('db/migrate', __dir__)

  def self.database_path
    raw = ENV.fetch('ORCHESTRATOR_DATA_DIR', 'data')
    return ':memory:' if raw == ':memory:'
    root = File.expand_path(raw, File.expand_path('..', __dir__))
    FileUtils.mkdir_p(root)
    File.join(root, 'orchestrator.db')
  end

  def self.establish_connection
    path = database_path
    ActiveRecord::Base.establish_connection(
      adapter:  'sqlite3',
      database: path,
      pool:     ENV.fetch('ORCHESTRATOR_DB_POOL', '10').to_i,
      timeout:  5000
    )
    return if path == ':memory:'
    conn = ActiveRecord::Base.connection
    conn.execute('PRAGMA journal_mode = WAL')
    conn.execute('PRAGMA synchronous = NORMAL')
    conn.execute('PRAGMA foreign_keys = ON')
  end

  def self.migrate!
    ActiveRecord::Base.connection.execute('PRAGMA foreign_keys = ON')
    ctx = ActiveRecord::MigrationContext.new(MIGRATIONS_PATH)
    ctx.migrate if ctx.needs_migration?
  end

  def self.boot!
    establish_connection
    migrate!
  end
end

DB.boot!

require_relative 'models/config_entry'
require_relative 'models/issue'
