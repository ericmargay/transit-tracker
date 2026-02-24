from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import declarative_base, sessionmaker
from sqlalchemy import Column, String, Float, DateTime, Boolean, Integer
from datetime import datetime, UTC
import uuid

from app.config import settings

engine = create_async_engine(settings.DATABASE_URL, echo=False)
AsyncSessionLocal = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
Base = declarative_base()


class VehicleReport(Base):
    __tablename__ = "vehicle_reports"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    line_id     = Column(String, nullable=False, index=True)
    session_id  = Column(String, nullable=False)
    latitude    = Column(Float, nullable=False)
    longitude   = Column(Float, nullable=False)
    heading     = Column(Float)
    speed_ms    = Column(Float)
    crowding    = Column(String)
    reported_at = Column(DateTime(timezone=True), default=lambda: datetime.now(UTC), index=True)


class AggregatedVehicle(Base):
    __tablename__ = "aggregated_vehicles"
    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    line_id      = Column(String, nullable=False, index=True)
    latitude     = Column(Float, nullable=False)
    longitude    = Column(Float, nullable=False)
    heading      = Column(Float)
    speed_ms     = Column(Float)
    crowding     = Column(String)
    report_count = Column(Integer, default=1)
    is_active    = Column(Boolean, default=True)
    updated_at   = Column(DateTime(timezone=True), default=lambda: datetime.now(UTC))


async def get_db():
    async with AsyncSessionLocal() as session:
        yield session


async def create_tables():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
