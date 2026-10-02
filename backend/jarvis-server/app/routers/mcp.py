from typing import Any, Optional, Union

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ..auth import require_api_key
from ..mcp_tools import call_tool, list_tools


router = APIRouter(
    prefix="/mcp",
    tags=["mcp"],
    dependencies=[Depends(require_api_key)],
)


class JsonRpcRequest(BaseModel):
    jsonrpc: str = "2.0"
    id: Optional[Union[int, str]] = None
    method: str
    params: dict[str, Any] = Field(default_factory=dict)


@router.get("/tools")
def get_tools():
    return {"tools": list_tools()}


@router.post("")
def jsonrpc(body: JsonRpcRequest):
    if body.method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": body.id,
            "result": {"tools": list_tools()},
        }
    if body.method == "tools/call":
        name = body.params.get("name", "")
        arguments = body.params.get("arguments") or {}
        user_id = body.params.get("user_id") or "default"
        result = call_tool(name, arguments, user_id=user_id)
        if result.get("is_error") and result.get("error", "").startswith("unknown tool"):
            return {
                "jsonrpc": "2.0",
                "id": body.id,
                "error": {"code": -32602, "message": result["error"]},
            }
        return {
            "jsonrpc": "2.0",
            "id": body.id,
            "result": {
                "content": [{"type": "text", "text": result.get("content") or result.get("error") or ""}],
                "structuredContent": result.get("structured_content", result),
                "isError": bool(result.get("is_error")),
            },
        }
    return {
        "jsonrpc": "2.0",
        "id": body.id,
        "error": {"code": -32601, "message": f"unknown method: {body.method}"},
    }
