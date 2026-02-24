#!/usr/bin/env bash
# Fix: stable wagon IDs through the full pipeline + correct passenger count

# ── 1. SIMULATION: each wagon has a stable ID, reports carry it ──────────
cat > backend/app/tasks/simulation.py << 'EOF'
import asyncio, json, math, random, logging, uuid
from pathlib import Path

logger      = logging.getLogger(__name__)
GEOJSON_DIR = Path("/app/geojson")

TICK_S         = 2
NOISE_M        = 8
METRO_MAX_MS   = 25.0
BUS_MAX_MS     = 14.0
METRO_ACCEL    = 1.2
BUS_ACCEL      = 0.7
DECEL_DIST     = 180
STATION_SPACING = 900
DWELL_MIN      = 18
DWELL_MAX      = 35

MAX_WAGONS = {
    "metro-1":7,"metro-2":7,"metro-3":7,"metro-4":5,
    "metro-5":6,"metro-6":5,"metro-7":6,"metro-8":6,
    "metro-9":6,"metro-a":5,"metro-b":7,"metro-12":6,
    "metrobus-1":8,"metrobus-2":7,"metrobus-3":7,
    "metrobus-4":6,"metrobus-5":5,"metrobus-6":6,"metrobus-7":6,
}

BUSY_ZONES = [
    (19.4252,-99.1344,700),(19.4319,-99.1401,500),
    (19.4270,-99.1674,400),(19.4711,-99.1194,400),
    (19.3580,-99.0719,400),(19.3987,-99.0586,350),
    (19.3296,-99.1876,350),(19.4847,-99.1952,350),
]

def haversine_m(lat1,lon1,lat2,lon2):
    R=6_371_000
    p1,p2=math.radians(lat1),math.radians(lat2)
    dp=math.radians(lat2-lat1); dl=math.radians(lon2-lon1)
    a=math.sin(dp/2)**2+math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return R*2*math.atan2(math.sqrt(a),math.sqrt(1-a))

def bearing(lat1,lon1,lat2,lon2):
    p1,p2=math.radians(lat1),math.radians(lat2)
    dl=math.radians(lon2-lon1)
    x=math.sin(dl)*math.cos(p2)
    y=math.cos(p1)*math.sin(p2)-math.sin(p1)*math.cos(p2)*math.cos(dl)
    return (math.degrees(math.atan2(x,y))+360)%360

def add_noise(lat,lon,r_m=NOISE_M):
    r=r_m/111_320; a=random.uniform(0,2*math.pi)
    return lat+r*math.sin(a),lon+r*math.cos(a)

def route_length(route):
    return sum(haversine_m(*route[i],*route[i+1]) for i in range(len(route)-1))

def build_route(features):
    segs=[f["geometry"]["coordinates"]
          for f in features if f.get("geometry",{}).get("type")=="LineString"]
    if not segs: return []
    result=list(segs[0])
    for seg in segs[1:]:
        if not seg: continue
        dff=haversine_m(result[-1][1],result[-1][0],seg[0][1], seg[0][0])
        dfr=haversine_m(result[-1][1],result[-1][0],seg[-1][1],seg[-1][0])
        if dfr<dff: seg=list(reversed(seg))
        if haversine_m(result[-1][1],result[-1][0],seg[0][1],seg[0][0])<3000:
            result.extend(seg[1:])
        else:
            result.extend(seg)
    return [(c[1],c[0]) for c in result]

def sample_at(route,dist_m):
    walked=0.0
    for i in range(len(route)-1):
        seg=haversine_m(*route[i],*route[i+1])
        if walked+seg>=dist_m:
            frac=(dist_m-walked)/max(seg,0.001)
            lat=route[i][0]+frac*(route[i+1][0]-route[i][0])
            lon=route[i][1]+frac*(route[i+1][1]-route[i][1])
            hdg=bearing(*route[i],*route[i+1])
            if i+2<len(route):
                hdg2=bearing(*route[i+1],*route[i+2])
                diff=((hdg2-hdg+180)%360)-180
                hdg=hdg+frac*diff
            return lat,lon,hdg%360
        walked+=seg
    return route[-1][0],route[-1][1],0.0

def in_busy_zone(lat,lon):
    for zlat,zlon,zr in BUSY_ZONES:
        d=haversine_m(lat,lon,zlat,zlon)
        if d<zr: return 1.0-(d/zr)
    return 0.0

class SimWagon:
    def __init__(self,line_id,route,max_ms,accel,offset_m,direction):
        # STABLE ID — never changes for the lifetime of this wagon
        self.wagon_id  = f"{line_id}-{str(uuid.uuid4())[:8]}"
        self.line_id   = line_id
        self.route     = route
        self.max_ms    = max_ms*random.uniform(0.88,1.0)
        self.accel     = accel
        self.length    = route_length(route)
        self.position  = offset_m%self.length
        self.direction = direction
        self.speed_ms  = 0.0
        self.dwell_left= random.uniform(0,DWELL_MAX)
        # passengers = 0-10 random riders
        self.passengers= random.randint(0,10)
        self._next_stop= random.uniform(400,STATION_SPACING)

    def step(self,dt_s):
        if self.dwell_left>0:
            self.dwell_left=max(0,self.dwell_left-dt_s)
            self.speed_ms=0.0
            return

        lat,lon,_=sample_at(self.route,self.position)
        busy=in_busy_zone(lat,lon)
        target_max=self.max_ms*(1.0-busy*0.75)
        if random.random()<0.02:
            target_max*=random.uniform(0.1,0.3)

        d_to_stop=self._next_stop
        if d_to_stop<DECEL_DIST:
            frac=d_to_stop/DECEL_DIST
            target_speed=target_max*max(0.02,frac)
        else:
            target_speed=target_max

        if self.speed_ms<target_speed:
            self.speed_ms=min(target_speed,self.speed_ms+self.accel*dt_s)
        else:
            self.speed_ms=max(target_speed,self.speed_ms-self.accel*2.5*dt_s)

        delta=self.speed_ms*dt_s
        self._next_stop-=delta
        self.position+=self.direction*delta

        if self._next_stop<=0:
            self.speed_ms=0.0
            self.dwell_left=random.uniform(DWELL_MIN,DWELL_MAX)
            if busy>0.4: self.dwell_left*=(1+busy)
            # Passenger churn: alight some, board some (0-10 total)
            alight=random.randint(0,min(self.passengers,4))
            board =random.randint(0,min(10-max(0,self.passengers-alight), int(2+busy*6)))
            self.passengers=max(0,min(10,self.passengers-alight+board))
            self._next_stop=random.uniform(STATION_SPACING*0.6,STATION_SPACING*1.4)

        if self.position>=self.length:
            self.position=self.length-(self.position-self.length)
            self.direction=-1; self.speed_ms=0.0
            self.dwell_left=random.uniform(DWELL_MIN,DWELL_MAX)
            self.passengers=random.randint(0,6)  # many alight at terminal
        elif self.position<=0:
            self.position=abs(self.position)
            self.direction=1; self.speed_ms=0.0
            self.dwell_left=random.uniform(DWELL_MIN,DWELL_MAX)
            self.passengers=random.randint(0,6)

    def get_report(self):
        """Single report per wagon — session_id IS the stable wagon_id."""
        route=self.route if self.direction==1 else list(reversed(self.route))
        pos  =self.position if self.direction==1 else self.length-self.position
        lat,lon,hdg=sample_at(route,pos)
        nlat,nlon=add_noise(lat,lon)
        return {
            "line_id":    self.line_id,
            "session_id": self.wagon_id,   # ← STABLE wagon identity
            "latitude":   nlat,
            "longitude":  nlon,
            "heading":    (hdg+random.gauss(0,2))%360,
            "speed_ms":   max(0.0,self.speed_ms),
            "crowding":   ("packed"    if self.passengers>7 else
                           "moderate"  if self.passengers>4 else
                           "light"     if self.passengers>1 else "empty"),
            "passengers": self.passengers,  # carry through for display
        }

def load_wagons():
    wagons=[]
    for gf in GEOJSON_DIR.glob("*_lines.geojson"):
        is_metro="metro_lines" in gf.name
        max_ms=METRO_MAX_MS if is_metro else BUS_MAX_MS
        accel =METRO_ACCEL  if is_metro else BUS_ACCEL
        try:
            features=json.loads(gf.read_text()).get("features",[])
        except Exception as e:
            logger.warning(f"{gf.name}: {e}"); continue
        by_line: dict[str,list]={}
        for f in features:
            lid=f.get("properties",{}).get("line_id","unknown")
            by_line.setdefault(lid,[]).append(f)
        for line_id,feats in by_line.items():
            route=build_route(feats)
            if len(route)<2: continue
            length=route_length(route)
            cap=MAX_WAGONS.get(line_id,6)
            n=min(cap,max(3,int(length/3000)))
            spacing=length/n
            logger.info(f"  {line_id}: {length/1000:.1f}km → {n} wagons")
            for i in range(n):
                w=SimWagon(line_id,route,max_ms,accel,
                           i*spacing+random.uniform(-50,50),
                           1 if i%2==0 else -1)
                wagons.append(w)
    logger.info(f"✅ {len(wagons)} wagons")
    return wagons

async def run_simulation(db_factory):
    wagons=load_wagons()
    if not wagons:
        logger.warning("No routes"); return
    from sqlalchemy import text as sa_text
    from app.routers.vehicles import broadcast_wagons_direct

    while True:
        t0=asyncio.get_event_loop().time()
        for w in wagons: w.step(TICK_S)

        # Group wagon states by line and broadcast directly
        # (bypass DB clustering — each wagon IS already one vehicle)
        by_line: dict[str,list]={}
        reports=[]
        for w in wagons:
            r=w.get_report()
            by_line.setdefault(w.line_id,[]).append({
                "wagon_id":    w.wagon_id,
                "latitude":    r["latitude"],
                "longitude":   r["longitude"],
                "heading":     r["heading"],
                "speed_ms":    r["speed_ms"],
                "speed_status":("stopped" if r["speed_ms"]<2.5 else
                                "slow"    if r["speed_ms"]<5.0 else "normal"),
                "passengers":  w.passengers,
            })
            reports.append(r)

        # Store in DB (for REST API)
        if reports:
            async with db_factory() as db:
                await db.execute(sa_text("""
                    INSERT INTO vehicle_reports
                        (id,line_id,session_id,latitude,longitude,
                         heading,speed_ms,crowding,reported_at)
                    VALUES
                        (gen_random_uuid(),:line_id,:session_id,:latitude,:longitude,
                         :heading,:speed_ms,:crowding,NOW())
                """), reports)
                await db.commit()

        # Broadcast directly (wagons already have stable IDs, no clustering needed)
        for line_id,vehicles in by_line.items():
            await broadcast_wagons_direct(line_id,vehicles)

        await asyncio.sleep(max(0.05,TICK_S-(asyncio.get_event_loop().time()-t0)))
EOF

# ── 2. ROUTER: add broadcast_wagons_direct ───────────────────────────────
cat > backend/app/routers/vehicles.py << 'EOF'
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
EOF

# ── 3. FRONTEND: match by wagon_id, not index ────────────────────────────
cat > frontend/src/App.tsx << 'EOF'
import { useEffect, useRef, useCallback, useState } from 'react'
import mapboxgl from 'mapbox-gl'
import 'mapbox-gl/dist/mapbox-gl.css'
import { lineById } from './data/lineRegistry'

mapboxgl.accessToken = import.meta.env.VITE_MAPBOX_TOKEN ?? ''
const WS_URL = (import.meta.env.VITE_WS_URL ?? 'ws://localhost:8001') + '/vehicles/ws'
const ALL_LINE_IDS = [
  'metro-1','metro-2','metro-3','metro-4','metro-5','metro-6',
  'metro-7','metro-8','metro-9','metro-a','metro-b','metro-12',
  'metrobus-1','metrobus-2','metrobus-3','metrobus-4',
  'metrobus-5','metrobus-6','metrobus-7',
]
const STATUS_COLOR: Record<string,string> = {
  normal:'#22c55e', slow:'#f59e0b', stopped:'#ef4444',
}
const INTERP_MS = 2000

interface VehicleState {
  wagon_id: string; line_id: string
  fromLng: number; fromLat: number; toLng: number; toLat: number
  fromHdg: number; toHdg: number
  speed_ms: number; speed_status: string; passengers: number
  startedAt: number
}

const lerp = (a:number,b:number,t:number) => a+(b-a)*t
function lerpAngle(a:number,b:number,t:number){
  const diff=((b-a+180)%360)-180
  return (a+diff*t+360)%360
}
function easeInOut(t:number){ return t<0.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2 }

function makeSprite(type:'metro'|'metrobus',color:string,size=64){
  const c=document.createElement('canvas'); c.width=size; c.height=size
  const ctx=c.getContext('2d')!
  const isM=type==='metro'
  const w=isM?size*0.88:size*0.54, h=isM?size*0.32:size*0.40
  const x=(size-w)/2, y=(size-h)/2, r=h/2
  ctx.shadowColor='rgba(0,0,0,0.55)'; ctx.shadowBlur=5; ctx.shadowOffsetY=2
  ctx.beginPath()
  ctx.moveTo(x+r,y); ctx.lineTo(x+w-r,y)
  ctx.quadraticCurveTo(x+w,y,x+w,y+r)
  ctx.lineTo(x+w,y+h-r)
  ctx.quadraticCurveTo(x+w,y+h,x+w-r,y+h)
  ctx.lineTo(x+r,y+h)
  ctx.quadraticCurveTo(x,y+h,x,y+h-r)
  ctx.lineTo(x,y+r)
  ctx.quadraticCurveTo(x,y,x+r,y)
  ctx.closePath()
  ctx.fillStyle=color; ctx.fill()
  ctx.shadowColor='transparent'
  ctx.fillStyle='rgba(255,255,255,0.20)'
  ctx.fillRect(x+w*0.14,y+h*0.18,w*0.72,h*0.28)
  ctx.strokeStyle='rgba(255,255,255,0.85)'; ctx.lineWidth=1.8; ctx.stroke()
  return ctx.getImageData(0,0,size,size)
}

export default function App() {
  const containerRef = useRef<HTMLDivElement>(null)
  const map          = useRef<mapboxgl.Map|null>(null)
  const ws           = useRef<WebSocket|null>(null)
  const rafId        = useRef<number>(0)
  const [ready, setReady] = useState(false)
  // KEY: wagon_id → state (stable, never re-keyed by index or line)
  const stateRef = useRef<Map<string,VehicleState>>(new Map())

  useEffect(()=>{
    if(map.current||!containerRef.current) return
    const m=new mapboxgl.Map({
      container:containerRef.current,
      style:'mapbox://styles/mapbox/dark-v11',
      center:[-99.1332,19.4326], zoom:11.2, attributionControl:false,
    })
    m.addControl(new mapboxgl.AttributionControl({compact:true}),'bottom-right')
    m.on('load',()=>{ map.current=m; initLayers(m); setReady(true) })
    return ()=>{ m.remove(); map.current=null }
  },[])

  const initLayers=useCallback(async(m:mapboxgl.Map)=>{
    for(const sys of ['metro','metrobus'] as const)
      for(const st of ['normal','slow','stopped'] as const){
        const d=makeSprite(sys,STATUS_COLOR[st])
        m.addImage(`wagon-${sys}-${st}`,{width:d.width,height:d.height,data:d.data})
      }
    const load=async(url:string)=>{
      const r=await fetch(url); if(!r.ok) throw new Error(url); return r.json()
    }
    try {
      const [mL,mS,bL,bS]=await Promise.all([
        load('/geojson/metro_lines.geojson'),
        load('/geojson/metro_stops.geojson'),
        load('/geojson/metrobus_lines.geojson').catch(()=>({type:'FeatureCollection',features:[]})),
        load('/geojson/metrobus_stops.geojson').catch(()=>({type:'FeatureCollection',features:[]})),
      ])
      for(const [id,data,w] of [
        ['metro-lines',mL,4],['metrobus-lines',bL,3]
      ] as [string,any,number][]){
        m.addSource(id,{type:'geojson',data})
        m.addLayer({id:`${id}-casing`,type:'line',source:id,
          layout:{'line-cap':'round','line-join':'round'},
          paint:{'line-color':'#000','line-width':w+3,'line-opacity':0.5}})
        m.addLayer({id:`${id}-fill`,type:'line',source:id,
          layout:{'line-cap':'round','line-join':'round'},
          paint:{'line-color':['get','line_color'],'line-width':w,'line-opacity':0.95}})
      }
      for(const [id,data] of [
        ['metro-stops',mS],['metrobus-stops',bS]
      ] as [string,any][]){
        m.addSource(id,{type:'geojson',data})
        m.addLayer({id:`${id}-dot`,type:'circle',source:id,
          paint:{
            'circle-color':'#fff',
            'circle-radius':['interpolate',['linear'],['zoom'],10,2,15,6],
            'circle-stroke-color':['get','line_color'],
            'circle-stroke-width':['interpolate',['linear'],['zoom'],10,1,15,3],
          }})
        m.addLayer({id:`${id}-lbl`,type:'symbol',source:id,minzoom:13,
          layout:{'text-field':['get','stop_name'],'text-size':10,
                  'text-offset':[0,1.3],'text-anchor':'top','text-optional':true},
          paint:{'text-color':'#fff','text-halo-color':'#000','text-halo-width':1.2}})
        m.on('mouseenter',`${id}-dot`,()=>m.getCanvas().style.cursor='pointer')
        m.on('mouseleave',`${id}-dot`,()=>m.getCanvas().style.cursor='')
        m.on('click',`${id}-dot`,(e)=>{
          const p=e.features?.[0]?.properties as any; if(!p) return
          const line=lineById(p.line_id)
          new mapboxgl.Popup({closeButton:false,offset:8}).setLngLat(e.lngLat)
            .setHTML(`<div style="font:13px/1.4 system-ui;padding:4px 8px">
              <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??''}</span>
              <div style="font-weight:600;margin-top:5px">${p.stop_name}</div>
            </div>`).addTo(m)
        })
      }
      m.addSource('vehicles',{type:'geojson',data:{type:'FeatureCollection',features:[]}})
      m.addLayer({id:'vehicle-icon',type:'symbol',source:'vehicles',
        layout:{
          'icon-image':             ['get','icon'],
          'icon-size':              ['interpolate',['linear'],['zoom'],9,0.45,12,0.75,15,1.3],
          'icon-rotate':            ['get','heading'],
          'icon-rotation-alignment':'map',
          'icon-allow-overlap':     true,
          'icon-ignore-placement':  true,
          'text-field':             ['get','label'],
          'text-size':              10,
          'text-font':              ['DIN Offc Pro Bold','Arial Unicode MS Bold'],
          'text-allow-overlap':     true,
          'text-ignore-placement':  true,
          'text-anchor':            'center',
          'text-rotation-alignment':'viewport',
        },
        paint:{'text-color':'#fff','text-halo-color':'rgba(0,0,0,0.5)','text-halo-width':1}
      })
      m.on('mouseenter','vehicle-icon',()=>m.getCanvas().style.cursor='pointer')
      m.on('mouseleave','vehicle-icon',()=>m.getCanvas().style.cursor='')
      m.on('click','vehicle-icon',(e)=>{
        const p=e.features?.[0]?.properties as any; if(!p) return
        const line=lineById(p.line_id)
        const kmh=(p.speed_ms*3.6).toFixed(0)
        const lbl: Record<string,string>={normal:'Normal ✅',slow:'Lento ⚠️',stopped:'Detenido 🔴'}
        new mapboxgl.Popup({closeButton:false,offset:14})
          .setLngLat((e.features![0].geometry as any).coordinates)
          .setHTML(`<div style="font:13px/1.6 system-ui;padding:6px 10px;min-width:160px">
            <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??p.line_id}</span>
            <div style="margin-top:6px;font-weight:700">${lbl[p.speed_status]??'—'}</div>
            <div style="color:#666;font-size:11px">${kmh} km/h · ${p.passengers} pasajero${p.passengers!==1?'s':''}</div>
          </div>`).addTo(m)
      })
    } catch(e){ console.warn('Layer error:',e) }
  },[])

  // rAF loop: interpolate each wagon by its stable wagon_id
  const renderLoop=useCallback(()=>{
    const m=map.current
    if(!m){ rafId.current=requestAnimationFrame(renderLoop); return }
    const src=m.getSource('vehicles') as mapboxgl.GeoJSONSource
    if(!src){ rafId.current=requestAnimationFrame(renderLoop); return }

    const now=performance.now()
    const features: GeoJSON.Feature[]=[]

    stateRef.current.forEach(v=>{
      const t=Math.min(1,(now-v.startedAt)/INTERP_MS)
      const e=easeInOut(t)
      const lng=lerp(v.fromLng,v.toLng,e)
      const lat=lerp(v.fromLat,v.toLat,e)
      const hdg=lerpAngle(v.fromHdg,v.toHdg,e)
      const line=lineById(v.line_id)
      const isMetro=v.line_id.startsWith('metro-')&&!v.line_id.startsWith('metrobus-')
      features.push({
        type:'Feature',
        geometry:{type:'Point',coordinates:[lng,lat]},
        properties:{
          line_id:     v.line_id,
          icon:        `wagon-${isMetro?'metro':'metrobus'}-${v.speed_status}`,
          heading:     hdg,
          speed_ms:    v.speed_ms,
          speed_status:v.speed_status,
          passengers:  v.passengers,
          label:       v.passengers>0 ? String(v.passengers) : '',
        }
      })
    })
    src.setData({type:'FeatureCollection',features})
    rafId.current=requestAnimationFrame(renderLoop)
  },[])

  useEffect(()=>{
    if(!ready) return
    rafId.current=requestAnimationFrame(renderLoop)

    const connect=()=>{
      const socket=new WebSocket(WS_URL)
      ws.current=socket
      socket.onopen=()=>
        ALL_LINE_IDS.forEach(id=>
          socket.send(JSON.stringify({type:'subscribe',payload:{line_id:id}}))
        )
      socket.onmessage=(e)=>{
        const msg=JSON.parse(e.data)
        if(msg.type!=='vehicle_update') return
        const {vehicles}=msg.payload
        const now=performance.now()

        ;(vehicles??[]).forEach((v: any)=>{
          const key=v.wagon_id   // ← stable wagon identity, never changes
          const prev=stateRef.current.get(key)
          stateRef.current.set(key,{
            wagon_id:    key,
            line_id:     msg.payload.lineId,
            fromLng:     prev?.toLng ?? v.longitude,
            fromLat:     prev?.toLat ?? v.latitude,
            toLng:       v.longitude,
            toLat:       v.latitude,
            fromHdg:     prev?.toHdg ?? (v.heading??0),
            toHdg:       v.heading??0,
            speed_ms:    v.speed_ms??0,
            speed_status:v.speed_status??'normal',
            passengers:  v.passengers??0,
            startedAt:   now,
          })
        })
      }
      socket.onclose=()=>setTimeout(connect,3000)
    }
    connect()
    return ()=>{ cancelAnimationFrame(rafId.current); ws.current?.close() }
  },[ready,renderLoop])

  return <div ref={containerRef} style={{width:'100vw',height:'100vh'}} />
}
EOF

echo "✅ Done. Run: docker compose restart backend"
