require_relative 'synthup'

module TaskRunner
  POLL_INTERVAL   = 8
  TIMEOUT         = 1800 # 30 minutes
  STALE_THRESHOLD = 600  # 10 min of identical content = session is stuck

  # Fractions of TIMEOUT at which to nudge the agent for the current JSON
  # report. Synthup may inject prompts (PR comments, failed checks) that
  # displace `last-message` after the agent emitted a report; the nudge asks
  # the agent to send the report reflecting current state.
  RECOVERY_THRESHOLDS = [0.5, 0.75, 0.9].freeze

  RECOVERY_PROMPT = <<~PROMPT.strip
    Please send your final JSON report reflecting the current state of the work, as the last fenced ```json block of your reply. If you are still working, continue — and remember to end the session with the JSON report.
  PROMPT

  class TimeoutError < StandardError; end

  KNOWN_REPORT_TYPES = %w[
    triage-report plan-report task-complete split-report test-report
    demo-review-pending demo-review-report discovery-complete
    create-issue-complete status-correction-report
    test-blocked task-failed blocked recovery-exhausted
  ].freeze

  def self.compose_prompt(task_file, context = {})
    raw = File.read(task_file)
    body = raw.sub(/\A---\n.*?\n---\n/m, '')

    return body if context.nil? || context.empty?

    context_lines = context.map { |k, v| "#{k}: #{v.is_a?(Hash) || v.is_a?(Array) ? v.to_json : v}" }
    "#{body}\n## Context\n\n#{context_lines.join("\n")}\n"
  end

  TASKS_DIR = File.expand_path('../tasks', __dir__)

  def self.find_task_file(task)
    path = File.join(TASKS_DIR, task)
    raise "Task file not found: #{task}" unless File.exist?(path)
    path
  end

  def self.parse_model(task_path)
    raw = File.read(task_path)
    match = raw.match(/\A---\n(.*?)\n---/m)
    return nil unless match
    frontmatter = match[1]
    model_match = frontmatter.match(/^model:\s*(.+)$/)
    model_match ? model_match[1].strip : nil
  end

  def self.poll_for_report(session_id, interval: POLL_INTERVAL, timeout: TIMEOUT, cancel_check: nil)
    deadline         = Time.now + timeout
    last_content     = nil
    last_changed_at  = nil
    started_at       = Time.now
    sid_short        = session_id.to_s.slice(0, 8)
    reminders_sent   = 0
    fired_thresholds = []

    loop do
      return { 'type' => 'cancelled' } if cancel_check&.call

      elapsed = (Time.now - started_at).round

      if Time.now > deadline
        warn "[poll #{sid_short}] +#{elapsed}s TIMEOUT after #{timeout}s — escalating to user"
        return recovery_exhausted_report(
          session_id:     session_id,
          reason:         "Session timed out after #{timeout}s without producing a JSON report",
          elapsed_s:      elapsed,
          reminders_sent: reminders_sent,
          last_content:   last_content
        )
      end

      msg = begin
        Synthup.get_last_message(session_id)
      rescue Synthup::Error
        raise
      rescue StandardError => e
        warn "[poll #{sid_short}] +#{elapsed}s transient error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
        sleep interval
        next
      end

      if msg.nil?
        warn "[poll #{sid_short}] +#{elapsed}s no message yet"
      else
        if session_failed?(msg)
          warn "[poll #{sid_short}] +#{elapsed}s session failed (status=#{msg['status'].inspect})"
          return failed_report(session_id, msg)
        end

        content     = msg['content']
        len         = content.is_a?(String) ? content.length : 0
        fence_count = content.is_a?(String) ? content.scan(/```/).length / 2 : 0
        report      = extract_report(content)

        if report
          warn "[poll #{sid_short}] +#{elapsed}s matched type=#{report['type']} (content=#{len}c, fences=#{fence_count})"
          return report
        end

        changed = content != last_content
        warn "[poll #{sid_short}] +#{elapsed}s no report match (content=#{len}c, fences=#{fence_count}, " \
             "changed=#{changed}, stale=#{last_changed_at ? (Time.now - last_changed_at).round : 0}s)"

        if changed
          last_content    = content
          last_changed_at = Time.now
        elsif last_changed_at && Time.now - last_changed_at > STALE_THRESHOLD
          warn "[poll #{sid_short}] +#{elapsed}s STALL — no new content for #{STALE_THRESHOLD}s — escalating to user"
          return recovery_exhausted_report(
            session_id:     session_id,
            reason:         "Session stalled — no new output for #{STALE_THRESHOLD}s",
            elapsed_s:      elapsed,
            reminders_sent: reminders_sent,
            last_content:   last_content
          )
        end
      end

      due_threshold = next_recovery_threshold(elapsed: elapsed, timeout: timeout, fired: fired_thresholds)
      if due_threshold
        fired_thresholds << due_threshold
        if send_recovery_reminder(session_id, sid_short, elapsed, due_threshold)
          reminders_sent += 1
        end
      end

      sleep interval
    end
  end

  def self.next_recovery_threshold(elapsed:, timeout:, fired:)
    RECOVERY_THRESHOLDS.find do |t|
      !fired.include?(t) && elapsed >= (timeout * t)
    end
  end

  def self.send_recovery_reminder(session_id, sid_short, elapsed, threshold)
    pct = (threshold * 100).round
    warn "[poll #{sid_short}] +#{elapsed}s sending recovery reminder (#{pct}% of timeout)"
    Synthup.send_message(session_id, prompt: RECOVERY_PROMPT)
    true
  rescue StandardError => e
    warn "[poll #{sid_short}] +#{elapsed}s reminder failed: #{e.class}: #{e.message}"
    false
  end

  def self.recovery_exhausted_report(session_id:, reason:, elapsed_s:, reminders_sent:, last_content:)
    tail = last_content.is_a?(String) ? last_content.slice(-500, 500) || last_content : nil
    details = +"#{reason}\n"
    details << "session_id: #{session_id}\n"
    details << "elapsed: #{elapsed_s}s\n"
    details << "reminders_sent: #{reminders_sent}\n"
    if tail && !tail.empty?
      details << "\nLast observed content (tail, up to 500 chars):\n"
      details << tail
    end
    { 'type' => 'recovery-exhausted', 'details' => details }
  end

  private

  def self.session_failed?(msg)
    return true if %w[failed error].include?(msg['status'])
    parsed = safe_parse_json(msg['content'].to_s)
    parsed.is_a?(Hash) && parsed.key?('error')
  end

  def self.failed_report(session_id, msg)
    detail = msg['content'].to_s.slice(0, 300)
    { 'type' => 'task-failed', 'details' => "Session #{session_id} failed: #{detail}" }
  end

  def self.extract_report(content)
    return nil unless content.is_a?(String)

    content.scan(/```(?:json)?\n(.*?)\n```/m).each do |match|
      parsed = safe_parse_json(match[0])
      next unless parsed.is_a?(Hash) && KNOWN_REPORT_TYPES.include?(parsed['type'])
      return parsed
    end

    nil
  end

  def self.safe_parse_json(str)
    JSON.parse(str)
  rescue JSON::ParserError
    nil
  end
end
