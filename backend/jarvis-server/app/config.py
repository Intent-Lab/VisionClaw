import os
from dataclasses import dataclass
from pathlib import Path
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env")


def required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value or "replace-with-" in value or value == "dev-secret-change-me":
        raise RuntimeError(f"Set {name} in backend/jarvis-server/.env or the environment")
    return value


@dataclass(frozen=True)
class Settings:
    database_url: str = required_env("DATABASE_URL")
    api_key: str = required_env("API_KEY")
    host: str = os.getenv("HOST", "0.0.0.0")
    port: int = int(os.getenv("PORT", "8000"))

    embedding_model: str = os.getenv("EMBEDDING_MODEL", "nlpai-lab/KURE-v1")
    embedding_dim: int = int(os.getenv("EMBEDDING_DIM", "1024"))
    face_embedding_dim: int = int(os.getenv("FACE_EMBEDDING_DIM", "512"))
    embedding_device: str = os.getenv("EMBEDDING_DEVICE", "cpu")

    gemini_api_key: str = os.getenv("GEMINI_API_KEY", "")

    openai_api_key: str = os.getenv("OPENAI_API_KEY") or os.getenv("GPT_API_KEY", "")
    openai_transcription_model: str = os.getenv(
        "OPENAI_TRANSCRIPTION_MODEL",
        "gpt-4o-mini-transcribe",
    )
    openai_summary_model: str = os.getenv(
        "OPENAI_SUMMARY_MODEL",
        "gpt-4.1-mini",
    )
    openai_reasoning_effort: str = os.getenv("OPENAI_REASONING_EFFORT", "low")
    jarvis_router_model: str = os.getenv("JARVIS_ROUTER_MODEL", "gpt-4.1-mini")
    jarvis_planner_model: str = os.getenv("JARVIS_PLANNER_MODEL", "gpt-4.1-mini")
    jarvis_answer_model: str = os.getenv("JARVIS_ANSWER_MODEL", "gpt-4.1-mini")

    google_client_id: str = os.getenv("GOOGLE_CLIENT_ID", "")
    google_client_secret: str = os.getenv("GOOGLE_CLIENT_SECRET", "")
    google_redirect_uri: str = os.getenv("GOOGLE_REDIRECT_URI", "")

    slack_client_id: str = os.getenv("SLACK_CLIENT_ID", "")
    slack_client_secret: str = os.getenv("SLACK_CLIENT_SECRET", "")
    slack_redirect_uri: str = os.getenv("SLACK_REDIRECT_URI", "")
    slack_default_channel_id: str = os.getenv("SLACK_DEFAULT_CHANNEL_ID", "")

    notion_client_id: str = os.getenv("NOTION_CLIENT_ID", "")
    notion_client_secret: str = os.getenv("NOTION_CLIENT_SECRET", "")
    notion_redirect_uri: str = os.getenv("NOTION_REDIRECT_URI", "")

    use_langgraph: bool = os.getenv("JARVIS_USE_LANGGRAPH", "false").lower() == "true"


settings = Settings()
