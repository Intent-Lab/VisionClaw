from typing import Any, Optional

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ..agent_service import confirm_pending_action, run_agent_query
from ..auth import require_api_key


router = APIRouter(
    prefix="/agent",
    tags=["agent"],
    dependencies=[Depends(require_api_key)],
)


class AgentQueryRequest(BaseModel):
    user_id: str = "default"
    text: str
    timezone: str = "Asia/Seoul"
    image_id: Optional[str] = None
    client_context: dict[str, Any] = Field(default_factory=dict)


class AgentConfirmRequest(BaseModel):
    user_id: str = "default"
    pending_action_id: str
    approved: bool = True


@router.post("/query")
def query(body: AgentQueryRequest):
    return run_agent_query(
        user_id=body.user_id,
        text=body.text,
        timezone=body.timezone,
        image_id=body.image_id,
        client_context=body.client_context,
    )


@router.post("/confirm")
def confirm(body: AgentConfirmRequest):
    return confirm_pending_action(
        user_id=body.user_id,
        pending_action_id=body.pending_action_id,
        approved=body.approved,
    )
