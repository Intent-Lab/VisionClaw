import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from .config import settings

# Default root logger level is WARNING, which would silently drop the app-level
# logger.info() calls (e.g. agent_flash's per-request Gemini call log) that make
# debugging via `tail -f api.log` over SSH possible without touching the phone.
# force=True because uvicorn already attaches its own root handlers before this
# module is imported, and plain basicConfig() is a no-op once handlers exist.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
    force=True,
)
from .db import close_pool, ensure_schema, open_pool
from .routers import (
    agent,
    agent_flash,
    integrations,
    live,
    mcp,
    meetings,
    memory,
    needs,
    people,
    proposals,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    open_pool()
    ensure_schema()
    yield
    close_pool()


app = FastAPI(
    title="Jarvis Memory API",
    version="0.1.0",
    description="Personal memory & CRM API for smart-glasses AI assistant.",
    lifespan=lifespan,
)

app.include_router(people.router)
app.include_router(meetings.router)
app.include_router(memory.router)
app.include_router(live.router)
app.include_router(needs.router)
app.include_router(proposals.router)
app.include_router(mcp.router)
app.include_router(agent.router)
app.include_router(agent_flash.router)
app.include_router(integrations.router)


@app.get("/health", tags=["health"])
def health():
    return {
        "status": "ok",
        "embedding_model": settings.embedding_model,
        "embedding_dim": settings.embedding_dim,
    }
