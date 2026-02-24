from fastapi import APIRouter
from app.data.line_registry import ALL_LINES

router = APIRouter(prefix="/lines", tags=["lines"])

@router.get("/")
async def get_lines():
    return ALL_LINES
