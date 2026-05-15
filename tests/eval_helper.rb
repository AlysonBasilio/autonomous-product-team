# frozen_string_literal: true
#
# Shared helpers for the Ruby eval suite. Loads tests/.env, exposes REPO_ROOT +
# task helpers, and wraps RubyLLM for OpenRouter chat calls.

require 'dotenv'
require 'ruby_llm'

Dotenv.load(File.expand_path('.env', __dir__))

module EvalHelper
  REPO_ROOT = File.expand_path('..', __dir__)

  RubyLLM.configure do |config|
    config.openrouter_api_key = ENV['OPENROUTER_API_KEY']
  end

  module_function

  def load_task(path)
    File.read(File.join(REPO_ROOT, path))
  end

  def parse_frontmatter_model(path)
    content = load_task(path)
    if content.start_with?('---')
      end_idx = content.index("\n---", 3)
      if end_idx
        if (match = content[3...end_idx].match(/^model:\s*(\S+)/m))
          return match[1]
        end
      end
    end
    raise "#{path} is missing a 'model:' field in YAML frontmatter"
  end

  def openrouter_available?
    !ENV['OPENROUTER_API_KEY'].to_s.empty?
  end

  # Single-turn chat: send `system` instructions + a `user` message, return content.
  # Mirrors the openai SDK call shape used by the old judge.py / test_*.py files.
  def openrouter_chat(model:, user:, system: nil, temperature: 0, max_tokens: 1024)
    chat = RubyLLM.chat(model: model, provider: :openrouter, assume_model_exists: true)
                  .with_temperature(temperature)
                  .with_params(max_tokens: max_tokens)
    chat.with_instructions(system) if system
    chat.ask(user).content.to_s
  end
end
