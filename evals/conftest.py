import os
from pathlib import Path

import openai
import pytest
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

REPO_ROOT = Path(__file__).parent.parent


def load_task(path: str) -> str:
    return (REPO_ROOT / path).read_text()


@pytest.fixture(scope="session")
def client():
    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        pytest.skip("OPENROUTER_API_KEY not set — skipping LLM eval")
    return openai.OpenAI(
        base_url="https://openrouter.ai/api/v1",
        api_key=api_key,
    )
