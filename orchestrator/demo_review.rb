require 'thread'

module DemoReview
  APPROVAL_TIMEOUT = 86_400  # 24 hours

  # Registers a pending approval on the server and blocks the calling thread
  # until the user clicks Approve or Redirect in the web UI, or the timeout elapses.
  #
  # Returns:
  #   { "outcome" => "approved"|"redirect"|"timeout", "user_feedback" => ..., "follow_up_issues" => [...] }
  def self.wait_for_approval(server:, pr_url:, issue_title: nil, summary: nil, issue_id: nil, kind: nil, **)
    mutex   = Mutex.new
    cond    = ConditionVariable.new
    result  = nil
    resolve = lambda { |h| mutex.synchronize { result = h; cond.signal } }

    server.pending_approval = {
      issue_title: issue_title,
      issue_id:    issue_id,
      pr_url:      pr_url,
      summary:     summary,
      kind:        kind,
      resolve:     resolve
    }

    deadline = Time.now + APPROVAL_TIMEOUT
    mutex.synchronize do
      while result.nil? && (remaining = deadline - Time.now) > 0
        cond.wait(mutex, remaining)
      end
    end

    server.pending_approval = nil

    result || { 'outcome' => 'timeout',
                'user_feedback' => "Demo review timed out after #{APPROVAL_TIMEOUT / 3600}h with no response" }
  end
end
