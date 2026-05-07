#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Entrypoint for the e2e suite. Loads tests/.env and requires every
# tests/e2e/test_*.rb. Each test_*.rb uses minitest/autorun, so the combined
# run fires when this file exits.
#
# Run: bundle exec ruby tests/e2e/run.rb
#
# Tests skip themselves with a clear message if SYNTHUP_* / E2E_GITHUB_REPO
# are not set in tests/.env. See AGENTS.md for the rules.

require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))

Dir[File.expand_path('test_*.rb', __dir__)].sort.each do |path|
  require_relative File.basename(path, '.rb')
end
