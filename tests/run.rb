#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Runs the entire eval suite. Each test_*.rb file uses minitest/autorun, so
# requiring them all triggers a single combined run when this file exits.
#
# Run: bundle exec ruby tests/run.rb
#
# LLM-judge tests skip themselves if OPENROUTER_API_KEY is unset; the static
# tests and extract_report unit tests always run.

Dir[File.expand_path('test_*.rb', __dir__)].sort.each do |path|
  require_relative File.basename(path, '.rb')
end
