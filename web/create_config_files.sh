#!/usr/bin/env bash
# ============================================================
#  Creates all missing config files for docker compose
#  Run from: web/
# ============================================================

set -e
echo "📝 Creating all missing config files..."

# ── docker-compose.yml ────────────────────────────────────────────────────
cat > docker-compose.yml << 'EOF'
services:
  db:
    image: postgis/postgis:16-3.4
    environment:
      POSTGRES_DB: transit_tracker
      POSTGRES_USER: transit
      POSTGRES_PASSWORD: transit_dev
    ports:
      - "5433:5432"
    volumes:
      - transit_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U transit -d transit_tracker"]
      interval: 5s
      retries: 5

  backend:
    build: ./backend
    ports:
      - "8001:8000"
    environment:
      DATABASE_URL: postgresql+asyncpg://transit:transit_dev@db:5432/transit_tracker
      MAPBOX_TOKEN: ${MAPBOX_TOKEN}
      ML_MODEL_PATH: /app/models
    volumes:
      - ./backend:/app
      - ml_models:/app/models
    depends_on:
      db:
        condition: service_healthy
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

  frontend:
    build: ./frontend
    ports:
      - "5173:5173"
    environment:
      VITE_API_URL: http://localhost:8001
      VITE_WS_URL: ws://localhost:8001
      VITE_MAPBOX_TOKEN: ${MAPBOX_TOKEN}
    volumes:
      - ./frontend:/app
      - /app/node_modules
    command: npm run dev -- --host

volumes:
  transit_pgdata:
  ml_models:
EOF
echo "  ✓ docker-compose.yml"

# ── backend/Dockerfile ────────────────────────────────────────────────────
cat > backend/Dockerfile << 'EOF'
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    libpq-dev \
    gcc \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
EOF
echo "  ✓ backend/Dockerfile"

# ── backend/requirements.txt ──────────────────────────────────────────────
cat > backend/requirements.txt << 'EOF'
fastapi==0.111.0
uvicorn[standard]==0.29.0
asyncpg==0.29.0
sqlalchemy[asyncio]==2.0.30
alembic==1.13.1
geoalchemy2==0.14.6
pydantic==2.7.0
pydantic-settings==2.2.1
websockets==12.0
httpx==0.27.0
shapely==2.0.4
geojson==3.1.0
lightgbm==4.3.0
scikit-learn==1.4.2
pandas==2.2.2
numpy==1.26.4
joblib==1.4.2
apscheduler==3.10.4
EOF
echo "  ✓ backend/requirements.txt"

# ── backend/app/config.py ─────────────────────────────────────────────────
cat > backend/app/config.py << 'EOF'
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://transit:transit_dev@db:5432/transit_tracker"
    MAPBOX_TOKEN: str = ""
    ML_MODEL_PATH: str = "/app/models"

    class Config:
        env_file = ".env"

settings = Settings()
EOF
echo "  ✓ backend/app/config.py"

# ── backend/app/main.py ───────────────────────────────────────────────────
cat > backend/app/main.py << 'EOF'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager

from app.models.database import create_tables


@asynccontextmanager
async def lifespan(app: FastAPI):
    await create_tables()
    yield


app = FastAPI(
    title="CDMX Transit Tracker API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    return {"status": "ok"}
EOF
echo "  ✓ backend/app/main.py"

# ── backend/app/models/database.py ───────────────────────────────────────
cat > backend/app/models/database.py << 'EOF'
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import declarative_base, sessionmaker
from sqlalchemy import Column, String, Float, DateTime, Boolean, Integer
from geoalchemy2 import Geometry
from datetime import datetime, UTC
import uuid

from app.config import settings

engine = create_async_engine(settings.DATABASE_URL, echo=False)
AsyncSessionLocal = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
Base = declarative_base()


class VehicleReport(Base):
    __tablename__ = "vehicle_reports"
    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    line_id      = Column(String, nullable=False, index=True)
    session_id   = Column(String, nullable=False)
    position     = Column(Geometry("POINT", srid=4326), nullable=False)
    heading      = Column(Float)
    speed_ms     = Column(Float)
    crowding     = Column(String)
    reported_at  = Column(DateTime(timezone=True), default=lambda: datetime.now(UTC), index=True)


class AggregatedVehicle(Base):
    __tablename__ = "aggregated_vehicles"
    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    line_id      = Column(String, nullable=False, index=True)
    position     = Column(Geometry("POINT", srid=4326), nullable=False)
    heading      = Column(Float)
    speed_ms     = Column(Float)
    crowding     = Column(String)
    report_count = Column(Integer, default=1)
    valid_from   = Column(DateTime(timezone=True))
    valid_until  = Column(DateTime(timezone=True))
    is_active    = Column(Boolean, default=True)


async def get_db():
    async with AsyncSessionLocal() as session:
        yield session


async def create_tables():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
EOF
echo "  ✓ backend/app/models/database.py"

# ── backend/app/models/schemas.py ────────────────────────────────────────
cat > backend/app/models/schemas.py << 'EOF'
from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime
from enum import Enum


class CrowdingLevel(str, Enum):
    empty    = "empty"
    light    = "light"
    moderate = "moderate"
    packed   = "packed"


class VehicleReportCreate(BaseModel):
    line_id:    str
    session_id: str
    latitude:   float = Field(..., ge=-90,  le=90)
    longitude:  float = Field(..., ge=-180, le=180)
    heading:    Optional[float] = None
    speed_ms:   Optional[float] = None
    crowding:   Optional[CrowdingLevel] = None


class VehiclePosition(BaseModel):
    id:           str
    line_id:      str
    latitude:     float
    longitude:    float
    heading:      Optional[float]
    speed_ms:     Optional[float]
    crowding:     Optional[CrowdingLevel]
    report_count: int
    updated_at:   datetime


class WSMessageType(str, Enum):
    vehicle_update    = "vehicle_update"
    prediction_update = "prediction_update"
    subscribe         = "subscribe"
    unsubscribe       = "unsubscribe"
    error             = "error"


class WSMessage(BaseModel):
    type:    WSMessageType
    payload: dict
EOF
echo "  ✓ backend/app/models/schemas.py"

# ── backend/app/websocket/hub.py ──────────────────────────────────────────
cat > backend/app/websocket/hub.py << 'EOF'
import asyncio
import json
from typing import Dict, Set
from fastapi import WebSocket
import logging

logger = logging.getLogger(__name__)


class ConnectionHub:
    def __init__(self):
        self._subscribers: Dict[str, Set[WebSocket]] = {}
        self._all_connections: Set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        async with self._lock:
            self._all_connections.add(websocket)

    async def disconnect(self, websocket: WebSocket):
        async with self._lock:
            self._all_connections.discard(websocket)
            for subs in self._subscribers.values():
                subs.discard(websocket)

    async def subscribe(self, websocket: WebSocket, line_id: str):
        async with self._lock:
            self._subscribers.setdefault(line_id, set()).add(websocket)

    async def unsubscribe(self, websocket: WebSocket, line_id: str):
        async with self._lock:
            if line_id in self._subscribers:
                self._subscribers[line_id].discard(websocket)

    async def broadcast_to_line(self, line_id: str, message: dict):
        subscribers = self._subscribers.get(line_id, set()).copy()
        if not subscribers:
            return
        payload = json.dumps(message)
        dead = set()
        for ws in subscribers:
            try:
                await ws.send_text(payload)
            except Exception:
                dead.add(ws)
        if dead:
            async with self._lock:
                for ws in dead:
                    self._all_connections.discard(ws)
                    for subs in self._subscribers.values():
                        subs.discard(ws)

    @property
    def active_connections(self) -> int:
        return len(self._all_connections)


hub = ConnectionHub()
EOF
echo "  ✓ backend/app/websocket/hub.py"

# ── backend/app/routers/vehicles.py ──────────────────────────────────────
cat > backend/app/routers/vehicles.py << 'EOF'
from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text
from datetime import datetime, timedelta, UTC
import json

from app.models.database import get_db, VehicleReport
from app.models.schemas import VehicleReportCreate, WSMessage, WSMessageType
from app.websocket.hub import hub

router = APIRouter(prefix="/vehicles", tags=["vehicles"])


@router.post("/report")
async def submit_report(report: VehicleReportCreate, db: AsyncSession = Depends(get_db)):
    db_report = VehicleReport(
        line_id    = report.line_id,
        session_id = report.session_id,
        position   = f"SRID=4326;POINT({report.longitude} {report.latitude})",
        heading    = report.heading,
        speed_ms   = report.speed_ms,
        crowding   = report.crowding.value if report.crowding else None,
    )
    db.add(db_report)
    await db.commit()
    await _aggregate_and_broadcast(report.line_id, db)
    return {"status": "ok"}


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await hub.connect(websocket)
    try:
        while True:
            raw = await websocket.receive_text()
            message = WSMessage(**json.loads(raw))
            if message.type == WSMessageType.subscribe:
                await hub.subscribe(websocket, message.payload["line_id"])
            elif message.type == WSMessageType.unsubscribe:
                await hub.unsubscribe(websocket, message.payload["line_id"])
    except WebSocketDisconnect:
        await hub.disconnect(websocket)


async def _aggregate_and_broadcast(line_id: str, db: AsyncSession):
    cutoff = datetime.now(UTC) - timedelta(minutes=3)
    result = await db.execute(
        text("""
            SELECT
                AVG(ST_X(position::geometry)) as avg_lon,
                AVG(ST_Y(position::geometry)) as avg_lat,
                AVG(heading)                  as avg_heading,
                AVG(speed_ms)                 as avg_speed,
                COUNT(*)                      as report_count,
                MODE() WITHIN GROUP (ORDER BY crowding) as mode_crowding
            FROM vehicle_reports
            WHERE line_id = :line_id AND reported_at > :cutoff
        """),
        {"line_id": line_id, "cutoff": cutoff}
    )
    row = result.fetchone()
    if row and row.avg_lat:
        await hub.broadcast_to_line(line_id, {
            "type": "vehicle_update",
            "payload": {
                "lineId":      line_id,
                "latitude":    row.avg_lat,
                "longitude":   row.avg_lon,
                "heading":     row.avg_heading,
                "speedMs":     row.avg_speed,
                "reportCount": row.report_count,
                "crowding":    row.mode_crowding,
                "updatedAt":   datetime.now(UTC).isoformat(),
            }
        })
EOF
echo "  ✓ backend/app/routers/vehicles.py"

# ── backend/app/routers/__init__.py ──────────────────────────────────────
cat > backend/app/routers/__init__.py << 'EOF'
EOF

# ── backend/app/main.py (updated with routers) ───────────────────────────
cat > backend/app/main.py << 'EOF'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager

from app.models.database import create_tables
from app.routers.vehicles import router as vehicles_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    await create_tables()
    yield


app = FastAPI(title="CDMX Transit Tracker API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(vehicles_router)


@app.get("/health")
async def health():
    return {"status": "ok", "active_ws": 0}
EOF
echo "  ✓ backend/app/main.py (with routers)"

# ── frontend/Dockerfile ───────────────────────────────────────────────────
cat > frontend/Dockerfile << 'EOF'
FROM node:22-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --legacy-peer-deps

COPY . .

EXPOSE 5173
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]
EOF
echo "  ✓ frontend/Dockerfile"

# ── frontend/.env (vite needs VITE_ prefix) ───────────────────────────────
# Read MAPBOX_TOKEN from parent .env if it exists
if [ -f ".env" ]; then
  MAPBOX_TOKEN=$(grep MAPBOX_TOKEN .env | cut -d'=' -f2)
  cat > frontend/.env << ENVEOF
VITE_MAPBOX_TOKEN=${MAPBOX_TOKEN}
VITE_API_URL=http://localhost:8001
VITE_WS_URL=ws://localhost:8001
ENVEOF
  echo "  ✓ frontend/.env (token copied from web/.env)"
fi

echo "\n✅ All config files created!"
echo "\nNow run:"
echo "   docker compose up --build"
