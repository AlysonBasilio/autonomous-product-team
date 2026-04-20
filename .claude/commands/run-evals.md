Run the eval test suite for the autonomous product team project.

## Steps

1. **Check the venv** — if `evals/.venv` does not exist, create it and install dependencies:
   ```bash
   python3 -m venv evals/.venv && evals/.venv/bin/pip install -q -r evals/requirements.txt
   ```

2. **Run static checks** (no API key required):
   ```bash
   evals/.venv/bin/python -m pytest evals/test_static.py -v
   ```
   Report the results. If any static check fails, stop here and explain which structural invariant was broken.

3. **Check for OPENROUTER_API_KEY** — look for it in `evals/.env` or the current environment. If not found, report that LLM evals were skipped and tell the user how to set the key.

4. **Run LLM evals** (only if key is available):
   ```bash
   evals/.venv/bin/python -m pytest evals/test_triage.py evals/test_plan_routing.py evals/test_manager_routing.py -v
   ```

5. **Summarize results** — report pass/fail counts per file and call out any failures with the specific rubric criterion that failed.
