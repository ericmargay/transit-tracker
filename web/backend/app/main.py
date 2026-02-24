import asyncio, logging
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager

from app.models.database import create_tables, AsyncSessionLocal
from app.routers.vehicles import router as vehicles_router
from app.routers.lines import router as lines_router
from app.tasks.simulation import run_simulation

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await create_tables()
    sim_task = asyncio.create_task(run_simulation(AsyncSessionLocal))
    yield
    sim_task.cancel()
    try:
        await sim_task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="CDMX Transit Tracker", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.include_router(vehicles_router)
app.include_router(lines_router)


@app.get("/health")
async def health():
    return {"status": "ok"}
