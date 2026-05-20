#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'socket'
require 'bundler/setup'

dir = File.dirname(__FILE__)
$LOAD_PATH.unshift(dir)

require_relative 'db'
require_relative 'config'
require_relative 'projects'
require_relative 'synthup'
require_relative 'state'
require_relative 'issues'
require_relative 'router'
require_relative 'task_runner'
require_relative 'demo_review'
require_relative 'server'
require_relative 'run_project'

# ── Start web server ──────────────────────────────────────────────────────────

port = (ENV['PORT'] || ENV['ORCHESTRATOR_PORT'] || 4242).to_i
bind = ENV.fetch('ORCHESTRATOR_BIND', '127.0.0.1')
interactive = ENV['ORCHESTRATOR_INTERACTIVE'] == '1'

puts "Interactive mode: orchestrator will pause for approval before each action." if interactive

Thread.new do
  OrchestratorServer.run!(port: port, bind: bind, quiet: true)
end

puts "Orchestrator UI: http://localhost:#{port}"

# Wait for Puma to accept connections before dispatching the first task
20.times do
  Socket.tcp('127.0.0.1', port, connect_timeout: 0.1) { break }
rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
  sleep 0.1
end

# ── Wait for global config + at least one project ────────────────────────────

def wait_for_setup(port)
  cfg = Config.load
  return cfg if cfg.synthup_configured? && Projects.list.any?

  puts "Waiting for setup at http://localhost:#{port} …"
  loop do
    sleep 1
    cfg = Config.load
    next unless cfg.synthup_configured?
    next if Projects.list.empty?
    return cfg
  end
end

cfg = wait_for_setup(port)
Synthup.api_key = cfg.api_key

# ── Supervisor: one orchestration thread per project ─────────────────────────

trap('INT')  { puts "\nInterrupted."; exit 0 }
trap('TERM') { puts "\nTerminated.";  exit 0 }

threads = {}  # project_id => Thread

loop do
  ids = Projects.list.map(&:id)

  # Spawn threads for newly added projects
  ids.each do |id|
    next if threads[id] && threads[id].alive?
    threads[id] = Thread.new { run_project_loop(id, port: port, interactive: interactive) }
    puts "[supervisor] started loop for #{id}"
  end

  # Reap dead/finished threads so they get re-spawned if the project still exists
  threads.each_pair do |id, t|
    next if t.alive?
    t.join rescue nil
    threads.delete(id)
  end

  sleep 3
end
