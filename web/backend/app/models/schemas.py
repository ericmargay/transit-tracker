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
