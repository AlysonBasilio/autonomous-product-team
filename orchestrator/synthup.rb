require 'net/http'
require 'json'
require 'uri'

module Synthup
  BASE = 'https://www.synthup.dev'

  class Error < StandardError
    attr_reader :status, :body
    def initialize(status, body)
      @status = status
      @body   = body
      super("Synthup API error #{status}: #{body}")
    end
  end

  def self.create_session(tenant:, project:, prompt:, model: nil)
    payload = { tenant: tenant, project: project, prompt: prompt }
    payload[:model] = model if model
    post('/api/sessions', payload)
  end

  def self.get_last_message(session_id)
    get("/api/sessions/#{session_id}/last-message")
  rescue Error => e
    return nil if e.status == 404
    raise
  end

  def self.send_message(session_id, prompt:, model: nil)
    payload = { prompt: prompt }
    payload[:model] = model if model
    post("/api/sessions/#{session_id}/messages", payload)
    nil
  end

  def self.archive_session(session_id)
    post("/api/sessions/#{session_id}/archive", {})
    nil
  end

  def self.list_sessions(tenant)
    get("/api/sessions?tenant=#{URI.encode_www_form_component(tenant)}")
  end

  private

  def self.api_key
    key = ENV['SYNTHUP_API_KEY']
    raise 'SYNTHUP_API_KEY environment variable is not set' unless key
    key
  end

  def self.get(path)
    uri = URI("#{BASE}#{path}")
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{api_key}"
    req['Accept'] = 'application/json'
    request(uri, req)
  end

  def self.post(path, body)
    uri = URI("#{BASE}#{path}")
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{api_key}"
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json'
    req.body = body.to_json
    request(uri, req)
  end

  def self.request(uri, req, redirect_count = 0)
    raise Error.new(0, 'Too many redirects') if redirect_count > 5

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      res = http.request(req)
      if res.is_a?(Net::HTTPRedirection)
        new_uri = URI(res['location'])
        new_req = req.class.new(new_uri)
        req.each_header { |k, v| new_req[k] = v }
        new_req.body = req.body if req.respond_to?(:body)
        return request(new_uri, new_req, redirect_count + 1)
      end
      raise Error.new(res.code.to_i, res.body) unless res.is_a?(Net::HTTPSuccess)
      res.body.empty? ? nil : JSON.parse(res.body)
    end
  end
end
