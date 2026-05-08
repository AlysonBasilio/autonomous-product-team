# frozen_string_literal: true

require 'yaml'
require 'json'
require 'set'

module Template
  class Error < StandardError; end
  class MissingInputError < Error; end
  class UnknownPlaceholderError < Error; end
  class TypeMismatchError < Error; end

  IMPLICIT_KEYS = %w[project_url].freeze

  PLACEHOLDER_RE = /\{\{\s*(\w+|\.)\s*\}\}/.freeze
  SECTION_RE     = /\{\{#\s*(\w+)\s*\}\}(.*?)\{\{\/\s*\1\s*\}\}/m.freeze

  Spec = Struct.new(:required, :optional, :body, keyword_init: true)

  def self.render(task_path, context = {})
    spec = parse(task_path)
    ctx  = stringify_keys(context)

    missing = spec.required.reject { |k| present?(ctx[k]) }
    raise MissingInputError, "#{task_path}: missing required input(s): #{missing.join(', ')}" unless missing.empty?

    declared = (spec.required + spec.optional + IMPLICIT_KEYS).to_set
    validate_placeholders!(spec.body, declared, task_path)

    expand(spec.body, ctx, task_path)
  end

  def self.parse(path)
    raw = File.read(path)
    if (m = raw.match(/\A---\n(.*?)\n---\n/m))
      yaml = YAML.safe_load(m[1]) || {}
      body = raw.sub(/\A---\n.*?\n---\n/m, '')
    else
      yaml = {}
      body = raw
    end
    inputs = yaml['inputs'] || {}
    Spec.new(
      required: Array(inputs['required']).map(&:to_s),
      optional: Array(inputs['optional']).map(&:to_s),
      body:     body
    )
  end

  class << self
    private

    def validate_placeholders!(body, declared, path)
      keys = body.scan(PLACEHOLDER_RE).map(&:first) + body.scan(SECTION_RE).map(&:first)
      keys.uniq.each do |k|
        next if k == '.'
        next if declared.include?(k)
        raise UnknownPlaceholderError,
              "#{path}: {{#{k}}} is not declared in inputs.required, inputs.optional, or implicit keys"
      end
    end

    def expand(body, ctx, path)
      after_sections = body.gsub(SECTION_RE) do
        key   = Regexp.last_match(1)
        inner = Regexp.last_match(2)
        val   = ctx[key]
        next '' unless present?(val)

        sect_ctx = ctx.merge('.' => val, key => val)
        substitute_scalars(inner, sect_ctx, path, complex_ok_for: [key, '.'].to_set)
      end
      substitute_scalars(after_sections, ctx, path, complex_ok_for: Set.new)
    end

    def substitute_scalars(text, ctx, path, complex_ok_for:)
      text.gsub(PLACEHOLDER_RE) do
        key = Regexp.last_match(1)
        val = ctx[key]
        if val.is_a?(Hash) || val.is_a?(Array)
          unless complex_ok_for.include?(key)
            raise TypeMismatchError,
                  "#{path}: {{#{key}}} is a #{val.class}; wrap it in a {{##{key}}}…{{/#{key}}} section to render as JSON"
          end
          "```json\n#{JSON.pretty_generate(val)}\n```"
        else
          val.to_s
        end
      end
    end

    def present?(value)
      return false if value.nil?
      return false if value == false
      return false if value.respond_to?(:empty?) && value.empty?
      true
    end

    def stringify_keys(hash)
      return {} unless hash
      hash.each_with_object({}) { |(k, v), o| o[k.to_s] = v }
    end
  end
end
