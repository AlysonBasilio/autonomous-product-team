"""
Pytest wrapper around evals/test_extract_report.rb so the Ruby extract_report
unit tests run as part of the static suite (`pytest evals/`).
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
RUBY_TEST = Path(__file__).parent / "test_extract_report.rb"


def test_ruby_extract_report():
    if shutil.which("ruby") is None:
        pytest.skip("ruby not on PATH — skipping orchestrator extract_report tests")
    result = subprocess.run(
        ["ruby", str(RUBY_TEST)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"Ruby extract_report tests failed (exit {result.returncode}).\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
