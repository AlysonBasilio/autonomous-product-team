require_relative 'synthup'
require_relative 'template'

module TaskRunner
  POLL_INTERVAL   = 8
  TIMEOUT         = 1800 # 30 minutes
  STALE_THRESHOLD = (TIMEOUT * 0.8).to_i # identical content for this long = stuck

  # Fractions of TIMEOUT at which to nudge the agent for the current JSON
  # report. Synthup may inject prompts (PR comments, failed checks) that
  # displace `last-message` after the agent emitted a report; the nudge asks
  # the agent to send the report reflecting current state.
  RECOVERY_THRESHOLDS = [0.5, 0.75, 0.9].freeze

  RECOVERY_PROMPT_BASE = <<~PROMPT.strip
    Please send your final JSON report reflecting the current state of the work, as the last fenced ```json block of your reply. If you are still working, continue — and remember to end the session with the JSON report.
  PROMPT

  class TimeoutError < StandardError; end

  KNOWN_REPORT_TYPES = %w[
    triage-report plan-report task-complete test-report
    demo-review-pending demo-review-report discovery-complete
    create-issue-complete
    task-failed blocked recovery-exhausted
  ].freeze

  # Dependency statuses that do NOT block a dependent issue: Done plus the
  # Excluded terminal states (Canceled, deleted). Anything else (In Progress,
  # In Review, Todo, Backlog, ...) blocks.
  NON_BLOCKING_DEP_STATUSES = %w[done canceled cancelled deleted].freeze

  def self.compose_prompt(task_file, context = {})
    Template.render(task_file, context || {})
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

  def self.poll_for_report(session_id, interval: POLL_INTERVAL, timeout: TIMEOUT, cancel_check: nil, task_path: nil)
    deadline               = Time.now + timeout
    last_content           = nil
    last_changed_at        = nil
    started_at             = Time.now
    sid_short              = session_id.to_s.slice(0, 8)
    reminders_sent         = 0
    fired_thresholds       = []
    last_rejection_content = nil

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
      elsif session_failed?(msg)
        warn "[poll #{sid_short}] +#{elapsed}s session failed (status=#{msg['status'].inspect})"
        return failed_report(session_id, msg)
      elsif msg['role'] != 'assistant'
        warn "[poll #{sid_short}] +#{elapsed}s last message role=#{msg['role'].inspect} — waiting for assistant reply"
      else
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

        rejection = report_rejection_reason(content)
        if rejection && content != last_rejection_content
          warn "[poll #{sid_short}] +#{elapsed}s rejecting report: #{rejection}"
          if send_rejection_feedback(session_id, sid_short, elapsed, rejection)
            last_rejection_content = content
          end
        end

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
        if send_recovery_reminder(session_id, sid_short, elapsed, due_threshold, task_path)
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

  def self.send_recovery_reminder(session_id, sid_short, elapsed, threshold, task_path)
    pct = (threshold * 100).round
    warn "[poll #{sid_short}] +#{elapsed}s sending recovery reminder (#{pct}% of timeout)"
    Synthup.send_message(session_id, prompt: recovery_prompt(task_path))
    true
  rescue StandardError => e
    warn "[poll #{sid_short}] +#{elapsed}s reminder failed: #{e.class}: #{e.message}"
    false
  end

  def self.recovery_prompt(task_path)
    examples = extract_report_examples(task_path)
    return RECOVERY_PROMPT_BASE if examples.empty?
    blocks = examples.map { |e| "```json\n#{e}\n```" }.join("\n\n")
    "#{RECOVERY_PROMPT_BASE}\n\nThe expected JSON shape for this task is one of:\n\n#{blocks}"
  end

  # Extract fenced ```json examples from a task file whose `type` matches a known
  # report type. The reminder uses these so the agent emits a shape the poller
  # actually recognizes (rather than inventing a new type).
  def self.extract_report_examples(task_path)
    return [] unless task_path && File.exist?(task_path)
    raw = File.read(task_path)
    examples = []
    raw.scan(/^[ \t]*```json[ \t]*\n(.*?)\n[ \t]*```/m).each do |match|
      body = dedent(match[0])
      parsed = safe_parse_json(body)
      next unless parsed.is_a?(Hash) && KNOWN_REPORT_TYPES.include?(parsed['type'])
      examples << body
    end
    examples
  end

  def self.dedent(text)
    lines = text.split("\n", -1)
    indents = lines.reject { |l| l.strip.empty? }.map { |l| l[/^[ \t]*/].length }
    return text if indents.empty?
    min_indent = indents.min
    return text if min_indent.zero?
    lines.map { |l| l.length >= min_indent && l.start_with?(' ' * min_indent) ? l[min_indent..] : l }.join("\n")
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
      next if validation_failure(parsed)
      return parsed
    end

    nil
  end

  # Walk the same fenced JSON blocks as extract_report. If we find one whose
  # type matches a known report but it fails validation, return the message
  # we should send back to the session so the agent knows what to fix. Returns
  # nil if no rejectable block is present (e.g. the agent is still mid-work
  # and hasn't emitted a report yet).
  def self.report_rejection_reason(content)
    return nil unless content.is_a?(String)
    content.scan(/```(?:json)?\n(.*?)\n```/m).each do |match|
      parsed = safe_parse_json(match[0])
      next unless parsed.is_a?(Hash) && KNOWN_REPORT_TYPES.include?(parsed['type'])
      reason = validation_failure(parsed)
      return reason if reason
    end
    nil
  end

  # Per-type validation. Returns a human-readable failure message (which is
  # sent back to the agent verbatim) or nil if the report is acceptable.
  def self.validation_failure(parsed)
    case parsed['type']
    when 'triage-report' then triage_validation_failure(parsed)
    end
  end

  # A triage-report that names a `next_issue` must list that issue's ID in
  # `considered`. The agent populates `considered` with every issue it ran a
  # dependency lookup on; if `next_issue` isn't there, the agent picked an
  # issue it never actually inspected.
  #
  # The report must also be internally consistent: if `dependencies_checked`
  # lists a dep that's unresolved (not Done and not Excluded), then by the
  # task's own Definition of Blocked the next_issue is Blocked — the agent
  # contradicted itself and must re-pick.
  def self.triage_validation_failure(parsed)
    next_issue = parsed['next_issue']
    return nil if next_issue.nil?
    id = next_issue.is_a?(Hash) ? next_issue['id'] : next_issue
    considered = parsed['considered']
    if !considered.is_a?(Array)
      "Your triage-report named next_issue #{id.inspect} but is missing the required `considered` array. " \
        "Add `considered`: every non-Done issue ID for which you ran the per-issue dependency lookup (step 2a), " \
        "including #{id}. Also include `dependencies_checked` listing the dependencies you verified for #{id}. " \
        "If you have not actually run those lookups, run them now before re-emitting the report."
    elsif !considered.include?(id)
      "Your triage-report named next_issue #{id.inspect} but #{id} is not listed in `considered`. " \
        "That means you never ran the per-issue dependency lookup on #{id} — it may actually be blocked. " \
        "Run the per-issue dependency lookup on #{id} now (including formal links, body cross-references, and " \
        "semantic dependencies), verify every dependency is Done, then re-emit the report with #{id} in `considered` " \
        "and the verified dependencies in `dependencies_checked`. If any dependency is unresolved (not Done and not Excluded), " \
        "pick a different next_issue."
    else
      blocking = blocking_dependencies(parsed['dependencies_checked'])
      return nil if blocking.empty?
      noun = blocking.length == 1 ? 'a dependency' : 'dependencies'
      verb = blocking.length == 1 ? 'is' : 'are'
      "Your triage-report named next_issue #{id.inspect} but its `dependencies_checked` lists #{noun} that #{verb} " \
        "unresolved (not Done and not Excluded): #{blocking.join(', ')}. Per the task's Definition of Blocked, any " \
        "unresolved dependency blocks the issue — so #{id} is Blocked. Pick a different next_issue whose dependencies " \
        "are all resolved (Done or Excluded; Canceled counts as Excluded), or emit `next_issue: null` if no Ready issue exists."
    end
  end

  def self.blocking_dependencies(deps)
    return [] unless deps.is_a?(Array)
    deps.each_with_object([]) do |entry, acc|
      next unless entry.is_a?(String)
      _dep_id, status = entry.split(':', 2)
      next if status.nil?
      next if NON_BLOCKING_DEP_STATUSES.include?(status.strip.downcase)
      acc << entry
    end
  end

  def self.send_rejection_feedback(session_id, sid_short, elapsed, reason)
    Synthup.send_message(session_id, prompt: reason)
    true
  rescue StandardError => e
    warn "[poll #{sid_short}] +#{elapsed}s rejection feedback failed: #{e.class}: #{e.message}"
    false
  end

  def self.safe_parse_json(str)
    JSON.parse(str)
  rescue JSON::ParserError
    nil
  end
end
