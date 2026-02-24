from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text
from datetime import datetime, timedelta, UTC
from math import radians, sin, cos, sqrt, atan2
import json

from app.models.database import get_db, VehicleReport
from app.models.schemas import VehicleReportCreate, WSMessage, WSMessageType
from app.websocket.hub import hub

router = APIRouter(prefix="/vehicles", tags=["vehicles"])
CLUSTER_RADIUS_M = 400
WINDOW_MINUTES   = 3
SPEED_NORMAL_MS  = 5.0
SPEED_SLOW_MS    = 2.5

def haversine_m(lat1,lon1,lat2,lon2):
    R=6_371_000
    p1,p2=radians(lat1),radians(lat2)
    dp=radians(lat2-lat1); dl=radians(lon2-lon1)
    a=sin(dp/2)**2+cos(p1)*cos(p2)*sin(dl/2)**2
    return R*2*atan2(sqrt(a),sqrt(1-a))

def speed_status(s):
    if s is None: return "normal"
    if s>=SPEED_NORMAL_MS: return "normal"
    if s>=SPEED_SLOW_MS:   return "slow"
    return "stopped"

def cluster_reports(rows):
    points=[{"lat":r.lat,"lon":r.lon,"heading":r.heading,
             "speed":r.speed,"crowding":r.crowding,"sid":r.sid}
            for r in rows if r.lat is not None]
    if not points: return []
    clusters,assigned=[],[False]*len(points)
    for i,p in enumerate(points):
        if assigned[i]: continue
        cl=[p]; assigned[i]=True
        for j,q in enumerate(points):
            if assigned[j]: continue
            if haversine_m(p["lat"],p["lon"],q["lat"],q["lon"])<=CLUSTER_RADIUS_M:
                cl.append(q); assigned[j]=True
        clusters.append(cl)
    result=[]
    for cl in clusters:
        n=len(cl)
        speeds=[p["speed"] for p in cl if p["speed"] is not None]
        heads =[p["heading"] for p in cl if p["heading"] is not None]
        crowds=[p["crowding"] for p in cl if p["crowding"]]
        avg_spd=sum(speeds)/len(speeds) if speeds else None
        result.append({
            "wagon_id":    cl[0]["sid"],
            "latitude":    sum(p["lat"] for p in cl)/n,
            "longitude":   sum(p["lon"] for p in cl)/n,
            "heading":     sum(heads)/len(heads) if heads else None,
            "speed_ms":    avg_spd,
            "speed_status":speed_status(avg_spd),
            "crowding":    max(set(crowds),key=crowds.count) if crowds else None,
            "passengers":  n,
        })
    return result

@router.post("/report")
async def submit_report(report: VehicleReportCreate, db: AsyncSession=Depends(get_db)):
    db.add(VehicleReport(
        line_id=report.line_id,session_id=report.session_id,
        latitude=report.latitude,longitude=report.longitude,
        heading=report.heading,speed_ms=report.speed_ms,
        crowding=report.crowding.value if report.crowding else None,
    ))
    await db.commit()
    await aggregate_and_broadcast(report.line_id,db)
    return {"status":"ok"}

@router.get("/{line_id}")
async def get_vehicles(line_id:str,db:AsyncSession=Depends(get_db)):
    return cluster_reports(await _fetch_recent(line_id,db))

@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await hub.connect(websocket)
    try:
        while True:
            msg=WSMessage(**json.loads(await websocket.receive_text()))
            if msg.type==WSMessageType.subscribe:
                await hub.subscribe(websocket,msg.payload["line_id"])
            elif msg.type==WSMessageType.unsubscribe:
                await hub.unsubscribe(websocket,msg.payload["line_id"])
    except WebSocketDisconnect:
        await hub.disconnect(websocket)

async def _fetch_recent(line_id,db):
    cutoff=datetime.now(UTC)-timedelta(minutes=WINDOW_MINUTES)
    r=await db.execute(
        text("SELECT latitude AS lat,longitude AS lon,heading,"
             "speed_ms AS speed,crowding,session_id AS sid "
             "FROM vehicle_reports WHERE line_id=:l AND reported_at>:c"),
        {"l":line_id,"c":cutoff}
    )
    return r.fetchall()

async def aggregate_and_broadcast(line_id,db):
    vs=cluster_reports(await _fetch_recent(line_id,db))
    if vs:
        await hub.broadcast_to_line(line_id,{
            "type":"vehicle_update",
            "payload":{"lineId":line_id,"vehicles":vs,
                       "updatedAt":datetime.now(UTC).isoformat()}
        })

async def broadcast_wagons_direct(line_id: str, vehicles: list):
    """Called by simulation — bypasses clustering, uses pre-computed wagon states."""
    await hub.broadcast_to_line(line_id,{
        "type":"vehicle_update",
        "payload":{
            "lineId":    line_id,
            "vehicles":  vehicles,
            "updatedAt": datetime.now(UTC).isoformat(),
        }
    })
