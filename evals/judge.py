from dataclasses import dataclass, field
from typing import List

import openai

JUDGE_PROMPT = """\
You are an evaluation judge for an AI agent system. Given a task definition, a scenario, and the agent's output, \
judge whether the output satisfies each rubric criterion.

## Task Definition
{task_content}

## Scenario
{scenario_description}

## Simulated Context (what the agent was given as its environment)
{mock_context}

## Agent Output
{agent_output}

## Rubric
For EACH criterion below, respond with exactly:
CRITERION N: YES — <one-sentence reason>
or
CRITERION N: NO — <one-sentence reason>

{rubric}
"""


@dataclass
class GradeResult:
    passed: bool
    scores: List[dict] = field(default_factory=list)
    failure_reasons: List[str] = field(default_factory=list)


def grade(
    client: openai.OpenAI,
    scenario: dict,
    agent_output: str,
    task_content: str,
) -> GradeResult:
    rubric_str = "\n".join(
        f"CRITERION {i + 1}: {r}" for i, r in enumerate(scenario["rubric"])
    )
    prompt = JUDGE_PROMPT.format(
        task_content=task_content,
        scenario_description=scenario.get("description", scenario["name"]),
        mock_context=scenario["mock_context"],
        agent_output=agent_output,
        rubric=rubric_str,
    )
    response = client.chat.completions.create(
        model="anthropic/claude-haiku-4-5",
        messages=[
            {
                "role": "system",
                "content": "You are a strict eval judge. Follow the response format exactly.",
            },
            {"role": "user", "content": prompt},
        ],
        temperature=0,
        max_tokens=1024,
    )

    content = response.choices[0].message.content
    scores = []
    failure_reasons = []

    for i, criterion in enumerate(scenario["rubric"]):
        marker = f"CRITERION {i + 1}:"
        passed_criterion = False
        reason = "criterion not found in judge output"
        for line in content.splitlines():
            stripped = line.strip()
            if stripped.startswith(marker):
                rest = stripped[len(marker):].strip()
                passed_criterion = rest.upper().startswith("YES")
                reason = rest
                break
        scores.append({"criterion": criterion, "passed": passed_criterion, "reason": reason})
        if not passed_criterion:
            failure_reasons.append(f"[{criterion}] {reason}")

    return GradeResult(
        passed=len(failure_reasons) == 0,
        scores=scores,
        failure_reasons=failure_reasons,
    )
