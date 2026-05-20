require_relative 'db'

# Global config: Synthup credentials + the UI's currently-viewed project id.
# Resolution order (highest first): env > ConfigEntry row > nil.
# `active_project_id` is read/written only via the DB (env doesn't override it).
module Config
  Snapshot = Struct.new(:tenant, :api_key, :active_project_id, keyword_init: true) do
    def synthup_configured?
      !tenant.to_s.strip.empty? && !api_key.to_s.strip.empty?
    end
  end

  def self.load
    stored = ConfigEntry.pluck(:key, :value).to_h
    Snapshot.new(
      tenant:            env_or(ENV['SYNTHUP_TENANT'])  || stored['tenant'],
      api_key:           env_or(ENV['SYNTHUP_API_KEY']) || stored['api_key'],
      active_project_id: stored['active_project_id']
    ).freeze
  end

  def self.save_synthup_credentials(tenant:, api_key:)
    write_entry('tenant',  tenant.to_s.strip)
    write_entry('api_key', api_key.to_s.strip)
  end

  def self.set_active_project_id(id)
    write_entry('active_project_id', id)
  end

  def self.tenant_from_env?
    !env_or(ENV['SYNTHUP_TENANT']).nil?
  end

  def self.api_key_from_env?
    !env_or(ENV['SYNTHUP_API_KEY']).nil?
  end

  def self.env_or(value)
    s = value.to_s
    s.strip.empty? ? nil : s
  end

  def self.write_entry(key, value)
    entry = ConfigEntry.find_or_initialize_by(key: key)
    entry.value = value
    entry.save!
  end
end
