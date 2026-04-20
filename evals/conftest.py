import os
import re
from pathlib import Path

import openai
import pytest
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

REPO_ROOT = Path(__file__).parent.parent


def load_task(path: str) -> str:
    return (REPO_ROOT / path).read_text()


def parse_frontmatter_model(path: str) -> str:
    content = load_task(path)
    if content.startswith("---"):
        end = content.find("\n---", 3)
        if end != -1:
            match = re.search(r"^model:\s*(\S+)", content[3:end], re.MULTILINE)
            if match:
                return f"anthropic/{match.group(1)}"
    raise ValueError(f"{path} is missing a 'model:' field in YAML frontmatter")


@pytest.fixture(scope="session")
def client():
    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        pytest.skip("OPENROUTER_API_KEY not set — skipping LLM eval")
    return openai.OpenAI(
        base_url="https://openrouter.ai/api/v1",
        api_key=api_key,
    )
