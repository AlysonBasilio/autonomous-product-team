require_relative 'storage'

# Global config: Synthup credentials + the currently-active project id.
# Resolution order (highest first): env > data/config.json > nil.
# `active_project_id` is read/written only via the file (env doesn't override it).
module Config
  CONFIG_FILE = 'config.json'

  Snapshot = Struct.new(:tenant, :api_key, :active_project_id, keyword_init: true) do
    def synthup_configured?
      !tenant.to_s.strip.empty? && !api_key.to_s.strip.empty?
    end
  end

  def self.load
    file = Storage.default.read_json(CONFIG_FILE) || {}
    Snapshot.new(
      tenant:            (ENV['SYNTHUP_TENANT']  if ENV['SYNTHUP_TENANT'].to_s.strip != '') || file['tenant'],
      api_key:           (ENV['SYNTHUP_API_KEY'] if ENV['SYNTHUP_API_KEY'].to_s.strip != '') || file['api_key'],
      active_project_id: file['active_project_id']
    ).freeze
  end

  # Synthup credentials are written to file only — env values are not persisted.
  def self.save_synthup_credentials(tenant:, api_key:)
    Storage.default.update_json(CONFIG_FILE) do |cfg|
      cfg.merge('tenant' => tenant.to_s.strip, 'api_key' => api_key.to_s.strip)
    end
  end

  def self.set_active_project_id(id)
    Storage.default.update_json(CONFIG_FILE) do |cfg|
      cfg.merge('active_project_id' => id)
    end
  end

  def self.tenant_from_env?
    ENV['SYNTHUP_TENANT'].to_s.strip != ''
  end

  def self.api_key_from_env?
    ENV['SYNTHUP_API_KEY'].to_s.strip != ''
  end
end
