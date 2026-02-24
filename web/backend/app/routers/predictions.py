from fastapi import APIRouter
router = APIRouter(prefix="/predictions", tags=["predictions"])

@router.get("/{line_id}")
async def get_predictions(line_id: str):
    return []
