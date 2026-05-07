# frozen_string_literal: true
#
# Shared harness for tests/e2e/. Three concerns, no overlap:
#
#   OrchestratorProcess — spawns bin/start in an isolated tmp data dir on a
#                         free port, with ORCHESTRATOR_INTERACTIVE=1.
#   Gh                  — gh CLI wrappers used only at fixture boundaries
#                         (create issue at setup, close issue/PR at teardown).
#   Browser             — thin Ferrum wrapper. UI is the only assertion surface.
#
# Read tests/AGENTS.md (../../AGENTS.md) before changing this file.

require 'json'
require 'open3'
require 'socket'
require 'tmpdir'
require 'fileutils'
require 'ferrum'

module E2E
  REPO_ROOT = File.expand_path('../..', __dir__)

  class TimeoutError < StandardError; end

  # Raised when the orchestrator surfaces an escalation in the UI. We fail
  # fast on this rather than waiting for a downstream assertion to time out,
  # because no further progress is possible until a human resets state.
  class EscalatedError < StandardError; end

  # ── OrchestratorProcess ─────────────────────────────────────────────────────

  class OrchestratorProcess
    attr_reader :port, :data_dir, :log_path, :pid

    def initialize(env: {})
      @port     = pick_free_port
      @data_dir = Dir.mktmpdir('e2e-orch')
      @log_path = File.join(@data_dir, 'orchestrator.log')
      @env      = env
    end

    def start
      log = File.open(@log_path, 'w')
      env = ENV.to_h.merge(
        'ORCHESTRATOR_PORT'        => @port.to_s,
        'ORCHESTRATOR_DATA_DIR'    => @data_dir,
        'ORCHESTRATOR_INTERACTIVE' => '1'
      ).merge(@env)
      @pid = Process.spawn(
        env, File.join(REPO_ROOT, 'bin', 'start'),
        chdir: REPO_ROOT, out: log, err: log, pgroup: true
      )
      log.close
      wait_for_port
      self
    end

    def stop
      return unless @pid
      begin
        Process.kill('-TERM', @pid)
      rescue Errno::ESRCH, Errno::EPERM
        # already gone
      end
      deadline = Time.now + 5
      until Time.now > deadline
        return if Process.waitpid(@pid, Process::WNOHANG)
        sleep 0.2
      end
      begin
        Process.kill('-KILL', @pid)
      rescue Errno::ESRCH, Errno::EPERM
        # already gone
      end
      Process.waitpid(@pid) rescue nil
    ensure
      @pid = nil
    end

    def cleanup
      FileUtils.rm_rf(@data_dir) if @data_dir && File.directory?(@data_dir)
    end

    def url
      "http://127.0.0.1:#{@port}"
    end

    def tail_log(lines: 80)
      return '' unless File.exist?(@log_path)
      File.readlines(@log_path).last(lines).join
    end

    private

    def pick_free_port
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      server.close
      port
    end

    def wait_for_port(timeout: 30)
      deadline = Time.now + timeout
      until Time.now > deadline
        begin
          Socket.tcp('127.0.0.1', @port, connect_timeout: 0.2) { return }
        rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
          sleep 0.2
        end
      end
      raise TimeoutError, "orchestrator did not accept on :#{@port} within #{timeout}s"
    end
  end

  # ── Gh ──────────────────────────────────────────────────────────────────────

  module Gh
    module_function

    # Uses the REST API via `gh api` rather than `gh issue create` / `gh pr close`,
    # which speak GraphQL — REST is simpler, returns structured JSON directly,
    # and avoids any environment that gates GraphQL POSTs. Retries once on
    # transport-level timeouts (occasionally seen in restricted networks).
    def gh_api(method, path, fields: {})
      args = ['gh', 'api', '-X', method.to_s.upcase, path]
      fields.each { |k, v| args << '-f' << "#{k}=#{v}" }
      attempts = 0
      loop do
        attempts += 1
        stdout, stderr, status = Open3.capture3(*args)
        return [stdout, stderr, status] if status.success?
        transport_err = stderr.include?('i/o timeout') ||
                        stderr.include?('dial tcp') ||
                        stderr.include?('connection refused') ||
                        stderr.include?('connection reset')
        return [stdout, stderr, status] unless transport_err && attempts < 3
        sleep 2 * attempts
      end
    end

    def create_issue(repo:, title:, body:)
      stdout, stderr, status = gh_api(:POST, "repos/#{repo}/issues",
                                      fields: { title: title, body: body })
      raise "gh api create issue failed: #{stderr.empty? ? stdout : stderr}" unless status.success?
      data = JSON.parse(stdout)
      { number: data.fetch('number'), url: data.fetch('html_url') }
    end

    # Idempotent — closing an already-closed issue/PR returns 200 from REST.
    def close_issue(repo:, number:)
      gh_api(:PATCH, "repos/#{repo}/issues/#{number}", fields: { state: 'closed' })
      true
    end

    def close_pr(repo:, number:, delete_branch: true)
      branch = nil
      if delete_branch
        info_out, _, info_status = gh_api(:GET, "repos/#{repo}/pulls/#{number}")
        if info_status.success?
          parsed = JSON.parse(info_out) rescue nil
          branch = parsed&.dig('head', 'ref')
        end
      end
      gh_api(:PATCH, "repos/#{repo}/pulls/#{number}", fields: { state: 'closed' })
      if delete_branch && branch
        gh_api(:DELETE, "repos/#{repo}/git/refs/heads/#{branch}")
      end
      true
    end
  end

  # ── Browser ─────────────────────────────────────────────────────────────────
  #
  # Pure DOM access. Every assertion in an e2e test reads through these helpers.
  # If a future test needs something not exposed here, add a method that still
  # reads the DOM — never reach into the orchestrator's HTTP API.

  class Browser
    DEFAULT_TIMEOUT = 10  # seconds
    POLL_INTERVAL   = 0.25

    def initialize(headless: true)
      @browser = Ferrum::Browser.new(
        headless: headless,
        process_timeout: 20,
        timeout: DEFAULT_TIMEOUT
      )
    end

    def quit
      @browser&.quit
    rescue StandardError
      # ferrum sometimes raises on shutdown if chrome already died
    end

    def goto(url)
      @browser.go_to(url)
    end

    # Set the value of an input/textarea by id. Uses focus+type so the UI's
    # change-handler fires (matches what a real user would do).
    def fill(id, value)
      node = @browser.at_css("##{id}")
      raise "element ##{id} not found" unless node
      node.focus
      node.type(value)
    end

    # Click a button by its visible text label. Closer to user behaviour than
    # selector matching, and resilient to id changes.
    def click_text(label)
      clicked = @browser.evaluate(<<~JS)
        (() => {
          const target = #{label.to_json};
          const b = Array.from(document.querySelectorAll('button'))
                         .find(b => b.textContent.trim() === target);
          if (!b) return false;
          b.click();
          return true;
        })()
      JS
      raise "no button with label #{label.inspect}" unless clicked
    end

    # True when an element exists in the DOM AND does not have the .hidden
    # class — the UI's toggle for sectional visibility.
    def visible?(id)
      @browser.evaluate(<<~JS)
        (() => {
          const el = document.getElementById(#{id.to_json});
          if (!el) return false;
          return !el.classList.contains('hidden');
        })()
      JS
    end

    def text(id)
      @browser.evaluate(<<~JS)
        (() => {
          const el = document.getElementById(#{id.to_json});
          return el ? el.textContent : null;
        })()
      JS
    end

    def attr(selector, name)
      @browser.evaluate(<<~JS)
        (() => {
          const el = document.querySelector(#{selector.to_json});
          return el ? el.getAttribute(#{name.to_json}) : null;
        })()
      JS
    end

    # Wait until block returns truthy, polling. Raises TimeoutError on miss.
    # Also raises EscalatedError immediately if the orchestrator surfaces an
    # escalation in the UI — no further progress is possible from there.
    def wait_until(timeout:, hint:)
      deadline = Time.now + timeout
      until Time.now > deadline
        if (msg = escalation_message)
          raise EscalatedError, "orchestrator escalated while waiting for #{hint}: #{msg}"
        end
        result = yield
        return result if result
        sleep POLL_INTERVAL
      end
      raise TimeoutError, "timed out after #{timeout}s waiting for: #{hint}"
    end

    # Returns "reason — details" if #escalation is visible, else nil.
    # The DOM (ui.html:297-301, 412-419) is the single source of truth: when
    # the orchestrator escalates, the UI exposes #esc-reason and #esc-details.
    def escalation_message
      return nil unless visible?('escalation')
      reason  = (text('esc-reason')  || '').strip.gsub(/\s+/, ' ')
      details = (text('esc-details') || '').strip
      details = details[0, 400] + '…' if details.length > 400
      [reason, details].reject(&:empty?).join(' — ')
    end

    def wait_visible(id, timeout: DEFAULT_TIMEOUT)
      wait_until(timeout: timeout, hint: "##{id} to become visible") { visible?(id) }
    end

    def wait_hidden(id, timeout: DEFAULT_TIMEOUT)
      wait_until(timeout: timeout, hint: "##{id} to become hidden") { !visible?(id) }
    end

    def wait_text_in(id, substring:, timeout: DEFAULT_TIMEOUT)
      wait_until(
        timeout: timeout,
        hint:    "##{id} text to contain #{substring.inspect} (last seen: #{(text(id) || '').strip.inspect[0, 200]})"
      ) do
        t = text(id)
        t && t.include?(substring)
      end
    rescue TimeoutError => e
      # Re-raise with the *current* DOM snapshot — the hint above captures the
      # value at entry, but the value may have changed during the wait.
      raise TimeoutError, "#{e.message}; final value: #{(text(id) || '').strip.inspect[0, 200]}"
    end
  end
end
