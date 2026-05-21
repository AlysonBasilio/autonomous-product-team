#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'socket'
require 'bundler/setup'

dir = File.dirname(__FILE__)
$LOAD_PATH.unshift(dir)

require_relative 'db'
require_relative 'config'
require_relative 'synthup'
require_relative 'issues'
require_relative 'router'
require_relative 'task_runner'
require_relative 'demo_review'
require_relative 'run_issue'
require_relative 'server'

# ── Start web server ──────────────────────────────────────────────────────────

port        = (ENV['PORT'] || ENV['ORCHESTRATOR_PORT'] || 4242).to_i
bind        = ENV.fetch('ORCHESTRATOR_BIND', '127.0.0.1')
interactive = ENV['ORCHESTRATOR_INTERACTIVE'] == '1'

OrchestratorServer.set :port_value,      port
OrchestratorServer.set :interactive_mode, interactive

# ── Boot cleanup / resume ─────────────────────────────────────────────────────

# For each issue that had an active Synthup session when the server last stopped,
# resume polling it (with a nudge prompt) rather than discarding the work.
# Issues waiting for approval (current_task present but no session_id) are cleared.
Issue.where.not(current_task: nil).each do |issue|
  ct         = issue.current_task || {}
  session_id = ct['session_id']
  task       = ct['task']
  if session_id && task
    warn "[boot] resuming session #{session_id} for issue #{issue.id}"
    OrchestratorServer.spawn_issue_thread(issue,
      port:           port,
      interactive:    interactive,
      initial_action: { type: 'resume-session', session_id: session_id, task: task })
  else
    issue.update!(current_task: nil)
  end
end

puts "Interactive mode: orchestrator will pause for approval before each action." if interactive

Thread.new do
  OrchestratorServer.run!(port: port, bind: bind, quiet: true)
end

puts "Orchestrator UI: http://localhost:#{port}"

# Re-register after Puma starts so our handlers override Puma's.
sleep 0.1
trap('INT')  { puts "\nInterrupted."; exit 0 }
trap('TERM') { puts "\nTerminated.";  exit 0 }

sleep
