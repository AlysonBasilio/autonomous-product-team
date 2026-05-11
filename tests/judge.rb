# frozen_string_literal: true
#
# LLM-as-judge implementation. Replaces judge.py.
#
# Sends the task definition + scenario + agent output + rubric to a fixed
# judge model and parses "CRITERION N: YES/NO — reason" lines back into a
# structured grade.

require 'json'
require_relative 'eval_helper'

module Judge
  JUDGE_PROMPT = <<~PROMPT
    You are an evaluation judge for an AI agent system. Given a task definition, a scenario, and the agent's output, judge whether the output satisfies each rubric criterion.

    ## Task Definition
    %<task_content>s

    ## Scenario
    %<scenario_description>s

    ## Simulated Context (what the agent was given as its environment)
    %<mock_context>s

    ## Agent Output
    %<agent_output>s

    ## Rubric
    For EACH criterion below, respond with exactly:
    CRITERION N: YES — <one-sentence reason>
    or
    CRITERION N: NO — <one-sentence reason>

    %<rubric>s
  PROMPT

  FORMAT_CRITERION =
    'the agent\'s final output contains a fenced ```json code block whose contents ' \
    'parse as valid JSON and include a top-level "type" field'

  FENCED_JSON_RE = /```json\s*\n(.*?)\n```/m

  GradeResult = Struct.new(:passed, :scores, :failure_reasons, keyword_init: true)

  module_function

  def grade(scenario:, agent_output:, task_content:)
    format_score = check_format(agent_output)
    rubric = scenario[:rubric]
    rubric_str = rubric.each_with_index
                       .map { |r, i| "CRITERION #{i + 1}: #{r}" }
                       .join("\n")
    prompt = format(
      JUDGE_PROMPT,
      task_content: task_content,
      scenario_description: scenario[:description] || scenario[:name],
      mock_context: scenario[:mock_context],
      agent_output: agent_output,
      rubric: rubric_str,
    )

    content = EvalHelper.openrouter_chat(
      model: 'anthropic/claude-haiku-4-5',
      system: 'You are a strict eval judge. Follow the response format exactly.',
      user: prompt,
      temperature: 0,
      max_tokens: 2048,
    )

    scores = []
    failure_reasons = []
    rubric.each_with_index do |criterion, i|
      marker = "CRITERION #{i + 1}:"
      passed_criterion = false
      reason = 'criterion not found in judge output'
      content.each_line do |line|
        stripped = line.strip
        next unless stripped.start_with?(marker)

        rest = stripped[marker.length..].strip
        passed_criterion = rest.upcase.start_with?('YES')
        reason = rest
        break
      end
      scores << { criterion: criterion, passed: passed_criterion, reason: reason }
      failure_reasons << "[#{criterion}] #{reason}" unless passed_criterion
    end

    scores << format_score
    failure_reasons << "[#{FORMAT_CRITERION}] #{format_score[:reason]}" unless format_score[:passed]

    GradeResult.new(
      passed: failure_reasons.empty?,
      scores: scores,
      failure_reasons: failure_reasons,
    )
  end

  def grade_with_retries(scenario:, task_content:, max_attempts: 3, required_passes: 2)
    passes = 0
    fails = 0
    summaries = []
    last_passing = nil

    max_attempts.times do |i|
      agent_output = yield(i + 1)
      result = grade(scenario: scenario, agent_output: agent_output, task_content: task_content)
      if result.passed
        passes += 1
        last_passing = result
        summaries << "Attempt #{i + 1}: PASS"
      else
        fails += 1
        summaries << "Attempt #{i + 1}: FAIL — #{result.failure_reasons.join(' | ')}"
      end

      return last_passing if passes >= required_passes
      break if fails > max_attempts - required_passes
    end

    GradeResult.new(passed: false, scores: [], failure_reasons: summaries)
  end

  def check_format(agent_output)
    matches = agent_output.scan(FENCED_JSON_RE).map(&:first)
    if matches.empty?
      return { criterion: FORMAT_CRITERION, passed: false, reason: 'no fenced ```json block found' }
    end

    parsed =
      begin
        JSON.parse(matches.last)
      rescue JSON::ParserError => e
        return { criterion: FORMAT_CRITERION, passed: false, reason: "fenced JSON did not parse: #{e.message}" }
      end

    unless parsed.is_a?(Hash) && parsed.key?('type')
      return { criterion: FORMAT_CRITERION, passed: false, reason: 'fenced JSON missing top-level "type" field' }
    end

    { criterion: FORMAT_CRITERION, passed: true, reason: 'YES — fenced JSON parses with top-level type' }
  end
end
