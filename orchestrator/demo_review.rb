require 'thread'

module DemoReview
  # Registers a pending approval on the server and blocks the calling thread
  # until the user clicks Approve or Redirect in the web UI.
  #
  # Returns:
  #   { "outcome" => "approved"|"redirect", "user_feedback" => ..., "follow_up_issues" => [...] }
  def self.wait_for_approval(server:, pr_url:, issue_title: nil, summary: nil, issue_id: nil, **)
    mutex    = Mutex.new
    cond     = ConditionVariable.new
    result   = nil

    resolve = lambda do |outcome_hash|
      mutex.synchronize do
        result = outcome_hash
        cond.signal
      end
    end

    server.pending_approval = {
      issue_title: issue_title,
      issue_id:    issue_id,
      pr_url:      pr_url,
      summary:     summary,
      resolve:     resolve
    }
    server.broadcast_state

    mutex.synchronize { cond.wait(mutex) while result.nil? }

    server.pending_approval = nil
    server.broadcast_state

    result
  end
end
