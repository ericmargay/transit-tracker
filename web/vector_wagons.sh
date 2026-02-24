#!/usr/bin/env bash
# Vector wagon shapes + passenger simulation + dramatic speed changes

# ── 1. FRONTEND: vector wagon sprites + passenger count ──────────────────
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

const STATUS_COLOR: Record<string, string> = {
  normal:  '#22c55e',
  slow:    '#f59e0b',
  stopped: '#ef4444',
}

// Draw a metro wagon sprite (long rounded rectangle) onto a canvas
function drawMetroSprite(color: string, size = 48): HTMLCanvasElement {
  const c = document.createElement('canvas')
  c.width = size; c.height = size
  const ctx = c.getContext('2d')!
  const w = size * 0.85, h = size * 0.36
  const x = (size - w) / 2, y = (size - h) / 2
  const r = h / 2

  // Shadow
  ctx.shadowColor = 'rgba(0,0,0,0.5)'
  ctx.shadowBlur = 4

  // Body
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.lineTo(x + w - r, y)
  ctx.arcTo(x + w, y, x + w, y + r, r)
  ctx.lineTo(x + w, y + h - r)
  ctx.arcTo(x + w, y + h, x + w - r, y + h, r)
  ctx.lineTo(x + r, y + h)
  ctx.arcTo(x, y + h, x, y + h - r, r)
  ctx.lineTo(x, y + r)
  ctx.arcTo(x, y, x + r, y, r)
  ctx.closePath()
  ctx.fillStyle = color
  ctx.fill()

  // Window strip
  ctx.shadowBlur = 0
  ctx.fillStyle = 'rgba(255,255,255,0.25)'
  const ww = w * 0.72, wh = h * 0.3
  const wx = x + (w - ww) / 2, wy = y + h * 0.2
  ctx.fillRect(wx, wy, ww, wh)

  // White border
  ctx.strokeStyle = 'rgba(255,255,255,0.9)'
  ctx.lineWidth = 1.5
  ctx.stroke()

  return c
}

// Draw a metrobus sprite (shorter, taller rectangle)
function drawBusSprite(color: string, size = 48): HTMLCanvasElement {
  const c = document.createElement('canvas')
  c.width = size; c.height = size
  const ctx = c.getContext('2d')!
  const w = size * 0.55, h = size * 0.38
  const x = (size - w) / 2, y = (size - h) / 2
  const r = 5

  ctx.shadowColor = 'rgba(0,0,0,0.5)'
  ctx.shadowBlur = 4

  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.lineTo(x + w - r, y)
  ctx.arcTo(x + w, y, x + w, y + r, r)
  ctx.lineTo(x + w, y + h - r)
  ctx.arcTo(x + w, y + h, x + w - r, y + h, r)
  ctx.lineTo(x + r, y + h)
  ctx.arcTo(x, y + h, x, y + h - r, r)
  ctx.lineTo(x, y + r)
  ctx.arcTo(x, y, x + r, y, r)
  ctx.closePath()
  ctx.fillStyle = color
  ctx.fill()

  // Window
  ctx.shadowBlur = 0
  ctx.fillStyle = 'rgba(255,255,255,0.25)'
  ctx.fillRect(x + w*0.15, y + h*0.2, w*0.7, h*0.3)

  ctx.strokeStyle = 'rgba(255,255,255,0.9)'
  ctx.lineWidth = 1.5
  ctx.stroke()

  return c
}

export default function App() {
  const containerRef = useRef<HTMLDivElement>(null)
  const map          = useRef<mapboxgl.Map | null>(null)
  const ws           = useRef<WebSocket | null>(null)
  const vehicles     = useRef<Record<string, any[]>>({})
  const [ready, setReady] = useState(false)

  useEffect(() => {
    if (map.current || !containerRef.current) return
    map.current = new mapboxgl.Map({
      container: containerRef.current,
      style: 'mapbox://styles/mapbox/dark-v11',
      center: [-99.1332, 19.4326],
      zoom: 11.2,
      attributionControl: false,
    })
    map.current.addControl(new mapboxgl.AttributionControl({ compact: true }), 'bottom-right')
    map.current.on('load', () => { initLayers(map.current!); setReady(true) })
    return () => { map.current?.remove(); map.current = null }
  }, [])

  const initLayers = useCallback(async (m: mapboxgl.Map) => {
    const load = async (url: string) => {
      const r = await fetch(url); if (!r.ok) throw new Error(url); return r.json()
    }

    // Register sprites for each status × system combination
    const statuses = ['normal','slow','stopped']
    const systems  = ['metro','metrobus']
    for (const sys of systems) {
      for (const st of statuses) {
        const color   = STATUS_COLOR[st]
        const canvas  = sys === 'metro' ? drawMetroSprite(color) : drawBusSprite(color)
        const imgData = m.getCanvas().getContext('2d')!
          .createImageData(canvas.width, canvas.height)
        const ctx = canvas.getContext('2d')!
        const raw = ctx.getImageData(0, 0, canvas.width, canvas.height)
        imgData.data.set(raw.data)
        m.addImage(`wagon-${sys}-${st}`, {
          width: canvas.width, height: canvas.height, data: raw.data
        })
      }
    }

    try {
      const [metroLines, metroStops, mbLines, mbStops] = await Promise.all([
        load('/geojson/metro_lines.geojson'),
        load('/geojson/metro_stops.geojson'),
        load('/geojson/metrobus_lines.geojson').catch(() => ({type:'FeatureCollection',features:[]})),
        load('/geojson/metrobus_stops.geojson').catch(() => ({type:'FeatureCollection',features:[]})),
      ])

      // Line layers
      for (const [srcId, data, w] of [
        ['metro-lines',    metroLines, 4],
        ['metrobus-lines', mbLines,    3],
      ] as [string, any, number][]) {
        m.addSource(srcId, { type:'geojson', data })
        m.addLayer({ id:`${srcId}-casing`, type:'line', source:srcId,
          layout: { 'line-cap':'round','line-join':'round' },
          paint:  { 'line-color':'#000','line-width':w+3,'line-opacity':0.5 } })
        m.addLayer({ id:`${srcId}-fill`, type:'line', source:srcId,
          layout: { 'line-cap':'round','line-join':'round' },
          paint:  { 'line-color':['get','line_color'],'line-width':w,'line-opacity':0.95 } })
      }

      // Stop layers
      for (const [srcId, data] of [
        ['metro-stops',    metroStops],
        ['metrobus-stops', mbStops],
      ] as [string, any][]) {
        m.addSource(srcId, { type:'geojson', data })
        m.addLayer({ id:`${srcId}-circle`, type:'circle', source:srcId,
          paint: {
            'circle-color': '#fff',
            'circle-radius': ['interpolate',['linear'],['zoom'],10,2,15,6],
            'circle-stroke-color': ['get','line_color'],
            'circle-stroke-width': ['interpolate',['linear'],['zoom'],10,1,15,3],
          }
        })
        m.addLayer({ id:`${srcId}-label`, type:'symbol', source:srcId, minzoom:13,
          layout: { 'text-field':['get','stop_name'],'text-size':10,'text-offset':[0,1.4],'text-anchor':'top','text-optional':true },
          paint:  { 'text-color':'#fff','text-halo-color':'#000','text-halo-width':1.2 }
        })
        m.on('mouseenter',`${srcId}-circle`,()=>m.getCanvas().style.cursor='pointer')
        m.on('mouseleave',`${srcId}-circle`,()=>m.getCanvas().style.cursor='')
        m.on('click',`${srcId}-circle`,(e)=>{
          const p=e.features?.[0]?.properties as any; if(!p) return
          const line=lineById(p.line_id)
          new mapboxgl.Popup({closeButton:false,offset:8}).setLngLat(e.lngLat)
            .setHTML(`<div style="font:13px/1.4 system-ui;padding:4px 8px">
              <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??''}</span>
              <div style="font-weight:600;margin-top:5px">${p.stop_name}</div>
            </div>`).addTo(m)
        })
      }

      // Vehicle source
      m.addSource('vehicles', { type:'geojson', data:{type:'FeatureCollection',features:[]} })

      // Wagon icon layer — rotated by heading, icon chosen by system+status
      m.addLayer({ id:'vehicle-icon', type:'symbol', source:'vehicles',
        layout: {
          'icon-image':              ['get','icon'],
          'icon-size':               ['interpolate',['linear'],['zoom'],10,0.7,15,1.4],
          'icon-rotate':             ['get','heading'],
          'icon-rotation-alignment': 'map',
          'icon-allow-overlap':      true,
          'icon-ignore-placement':   true,
          'text-field':              ['get','label'],
          'text-size':               11,
          'text-font':               ['DIN Offc Pro Bold','Arial Unicode MS Bold'],
          'text-allow-overlap':      true,
          'text-ignore-placement':   true,
          'text-anchor':             'center',
          'text-rotation-alignment': 'viewport',
        },
        paint: { 'text-color':'#fff' }
      })

      m.on('mouseenter','vehicle-icon',()=>m.getCanvas().style.cursor='pointer')
      m.on('mouseleave','vehicle-icon',()=>m.getCanvas().style.cursor='')
      m.on('click','vehicle-icon',(e)=>{
        const p=e.features?.[0]?.properties as any; if(!p) return
        const line=lineById(p.line_id)
        const kmh=p.speed_ms?(p.speed_ms*3.6).toFixed(0):'—'
        const stLabel={normal:'Normal ✅',slow:'Lento ⚠️',stopped:'Detenido 🔴'}[p.speed_status as string]??''
        new mapboxgl.Popup({closeButton:false,offset:14})
          .setLngLat((e.features![0].geometry as any).coordinates)
          .setHTML(`<div style="font:13px/1.6 system-ui;padding:4px 10px;min-width:160px">
            <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??p.line_id}</span>
            <div style="margin-top:6px;font-weight:700">${stLabel}</div>
            <div style="color:#555;font-size:11px">${kmh} km/h</div>
            <div style="color:#555;font-size:11px">${p.passengers} pasajeros reportando</div>
          </div>`).addTo(m)
      })

    } catch(err) { console.warn('Layer error:', err) }
  }, [])

  const updateMap = useCallback(() => {
    if (!map.current) return
    const src = map.current.getSource('vehicles') as mapboxgl.GeoJSONSource
    if (!src) return
    const features: any[] = []
    for (const [lineId, clusters] of Object.entries(vehicles.current)) {
      const line    = lineById(lineId)
      const isMetro = lineId.startsWith('metro-') && !lineId.startsWith('metrobus-')
      const system  = isMetro ? 'metro' : 'metrobus'
      for (const v of clusters) {
        const status = v.speed_status ?? 'normal'
        features.push({
          type: 'Feature',
          geometry: { type:'Point', coordinates:[v.longitude, v.latitude] },
          properties: {
            line_id:      lineId,
            line_color:   line?.colorHex ?? '#fff',
            icon:         `wagon-${system}-${status}`,
            heading:      v.heading ?? 0,
            speed_ms:     v.speed_ms ?? 0,
            speed_status: status,
            passengers:   v.passengers ?? 0,
            label:        v.passengers > 0 ? String(v.passengers) : '',
          }
        })
      }
    }
    src.setData({ type:'FeatureCollection', features })
  }, [])

  useEffect(() => {
    if (!ready) return
    const connect = () => {
      const socket = new WebSocket(WS_URL)
      ws.current = socket
      socket.onopen = () =>
        ALL_LINE_IDS.forEach(id =>
          socket.send(JSON.stringify({ type:'subscribe', payload:{ line_id:id } }))
        )
      socket.onmessage = (e) => {
        const msg = JSON.parse(e.data)
        if (msg.type === 'vehicle_update') {
          vehicles.current[msg.payload.lineId] = msg.payload.vehicles ?? []
          updateMap()
        }
      }
      socket.onclose = () => setTimeout(connect, 3000)
    }
    connect()
    return () => ws.current?.close()
  }, [ready, updateMap])

  return <div ref={containerRef} style={{ width:'100vw', height:'100vh' }} />
}
EOF

# ── 2. SIMULATION: half wagons, passenger boarding/alighting ────────────
cat > backend/app/tasks/simulation.py << 'EOF'
"""
Realistic simulation with:
- Half wagon counts from real operations
- Passengers board at stops, ride some stops, then alight
- Crowded stations cause congestion → speed drops → red wagons
- Speed changes are dramatic enough to see clear color shifts
"""
import asyncio, json, math, random, logging
from pathlib import Path

logger = logging.getLogger(__name__)
GEOJSON_DIR = Path("/app/geojson")

REPORT_INTERVAL = 8
NOISE_M         = 18
METRO_SPEED_MS  = 9.5
BUS_SPEED_MS    = 5.5
STOP_DWELL_S    = 20

# HALF of real peak counts
MAX_WAGONS = {
    "metro-1": 9,  "metro-2": 9,  "metro-3": 9,  "metro-4": 5,
    "metro-5": 7,  "metro-6": 5,  "metro-7": 7,  "metro-8": 7,
    "metro-9": 7,  "metro-a": 6,  "metro-b": 8,  "metro-12": 7,
    "metrobus-1": 11, "metrobus-2": 8, "metrobus-3": 9,
    "metrobus-4": 7,  "metrobus-5": 4, "metrobus-6": 6, "metrobus-7": 6,
}

# Busy station clusters (lat, lon, radius_m) — where passengers pile up
BUSY_ZONES = [
    (19.4252, -99.1344, 800),   # Hidalgo / Centro
    (19.4319, -99.1401, 600),   # Balderas
    (19.4270, -99.1674, 500),   # Observatorio
    (19.4711, -99.1194, 500),   # Indios Verdes
    (19.3580, -99.0719, 500),   # Pantitlán
    (19.3987, -99.0586, 400),   # La Paz
    (19.3296, -99.1876, 400),   # Universidad
    (19.4847, -99.1952, 400),   # Cuatro Caminos
]


def haversine_m(lat1, lon1, lat2, lon2) -> float:
    R = 6_371_000
    φ1, φ2 = math.radians(lat1), math.radians(lat2)
    dφ, dλ = math.radians(lat2-lat1), math.radians(lon2-lon1)
    a = math.sin(dφ/2)**2 + math.cos(φ1)*math.cos(φ2)*math.sin(dλ/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))


def bearing(lat1, lon1, lat2, lon2) -> float:
    φ1, φ2 = math.radians(lat1), math.radians(lat2)
    dλ = math.radians(lon2-lon1)
    x = math.sin(dλ)*math.cos(φ2)
    y = math.cos(φ1)*math.sin(φ2) - math.sin(φ1)*math.cos(φ2)*math.cos(dλ)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def add_noise(lat, lon, r_m=NOISE_M):
    r = r_m / 111_320
    a = random.uniform(0, 2*math.pi)
    return lat + r*math.sin(a), lon + r*math.cos(a)


def in_busy_zone(lat, lon) -> float:
    """Returns congestion factor 0.0–1.0 based on proximity to busy stations."""
    for zlat, zlon, zr in BUSY_ZONES:
        d = haversine_m(lat, lon, zlat, zlon)
        if d < zr:
            return 1.0 - (d / zr)  # 1.0 at centre, 0.0 at edge
    return 0.0


def route_length(route) -> float:
    return sum(haversine_m(*route[i], *route[i+1]) for i in range(len(route)-1))


def build_route(features):
    segs = [f["geometry"]["coordinates"]
            for f in features if f.get("geometry",{}).get("type")=="LineString"]
    if not segs: return []
    result = list(segs[0])
    for seg in segs[1:]:
        if not seg: continue
        d_ff = haversine_m(result[-1][1],result[-1][0],seg[0][1], seg[0][0])
        d_fr = haversine_m(result[-1][1],result[-1][0],seg[-1][1],seg[-1][0])
        if d_fr < d_ff: seg = list(reversed(seg))
        if haversine_m(result[-1][1],result[-1][0],seg[0][1],seg[0][0]) < 3000:
            result.extend(seg[1:])
        else:
            result.extend(seg)
    return [(c[1], c[0]) for c in result]


def sample_at(route, dist_m):
    walked = 0.0
    for i in range(len(route)-1):
        seg = haversine_m(*route[i], *route[i+1])
        if walked + seg >= dist_m:
            frac = (dist_m - walked) / max(seg, 0.001)
            lat  = route[i][0] + frac*(route[i+1][0]-route[i][0])
            lon  = route[i][1] + frac*(route[i+1][1]-route[i][1])
            hdg  = bearing(*route[i], *route[i+1])
            return lat, lon, hdg
        walked += seg
    return route[-1][0], route[-1][1], 0.0


class Passenger:
    """A single reporting passenger with a random trip length."""
    def __init__(self):
        self.stops_remaining = random.randint(1, 8)  # how many more stops to ride

    def tick(self) -> bool:
        """Returns True if still riding, False if alighted."""
        self.stops_remaining -= 1
        return self.stops_remaining > 0


class SimWagon:
    def __init__(self, line_id, route, cruise_ms, offset_m, direction):
        self.line_id      = line_id
        self.route        = route
        self.cruise_ms    = cruise_ms * random.uniform(0.9, 1.1)
        self.length       = route_length(route)
        self.position     = offset_m % self.length
        self.direction    = direction
        self.speed_ms     = cruise_ms
        self.dwell_left   = 0
        self._phase       = random.uniform(0, math.pi*2)
        self.passengers: list[Passenger] = []
        self._at_stop     = False

    def step(self, dt_s):
        # ── Dwell at terminal ──────────────────────────────────────────
        if self.dwell_left > 0:
            self.dwell_left -= dt_s
            self.speed_ms = 0
            return

        # ── Passenger simulation at stations ──────────────────────────
        # Detect "at stop" by checking if phase just crossed π (deceleration trough)
        prev_phase = self._phase
        self._phase += dt_s * 0.09   # ~70s between stops
        crossed_stop = (int(prev_phase / math.pi) != int(self._phase / math.pi))

        if crossed_stop:
            # Alighting: passengers tick down, remove those who get off
            self.passengers = [p for p in self.passengers if p.tick()]
            # Boarding: 0–5 new passengers board
            lat, lon, _ = sample_at(self.route, self.position)
            busy = in_busy_zone(lat, lon)
            # More boarding at busy stations
            max_board = int(3 + busy * 7)   # 3 normal, up to 10 at busy zones
            n_board = random.randint(0, min(max_board, 10 - len(self.passengers)))
            for _ in range(n_board):
                self.passengers.append(Passenger())
            # Congestion at busy zone slows wagon more dramatically
            if busy > 0.5:
                self.dwell_left = STOP_DWELL_S * (1 + busy)  # longer dwell when crowded

        # ── Speed: oscillate + congestion penalty ─────────────────────
        speed_factor = 0.5 + 0.5 * abs(math.sin(self._phase))

        # Get current position to check busy zone
        lat, lon, _ = sample_at(self.route, self.position)
        congestion = in_busy_zone(lat, lon)

        # Congestion dramatically reduces speed (this creates the red spots)
        # 0 congestion → normal, 0.5 → 50% speed, 1.0 → nearly stopped
        congestion_penalty = 1.0 - (congestion * 0.85)
        speed_factor *= congestion_penalty

        # Random incidents (3% chance of sudden slowdown)
        if random.random() < 0.03:
            speed_factor *= random.uniform(0.05, 0.3)

        self.speed_ms = self.cruise_ms * max(0.05, speed_factor) * random.uniform(0.92, 1.08)

        self.position += self.speed_ms * self.direction * dt_s
        if self.position >= self.length:
            self.position = self.length - (self.position - self.length)
            self.direction = -1
            self.dwell_left = STOP_DWELL_S
            self.speed_ms = 0
            self.passengers = [p for p in self.passengers if p.tick()]
        elif self.position <= 0:
            self.position = abs(self.position)
            self.direction = 1
            self.dwell_left = STOP_DWELL_S
            self.speed_ms = 0
            self.passengers = [p for p in self.passengers if p.tick()]

    def get_reports(self):
        n = len(self.passengers)
        if n == 0:
            return []   # invisible this tick
        route = self.route if self.direction == 1 else list(reversed(self.route))
        pos   = self.position if self.direction == 1 else self.length - self.position
        lat, lon, hdg = sample_at(route, pos)
        return [{
            "line_id":    self.line_id,
            "latitude":   add_noise(lat, lon)[0],
            "longitude":  add_noise(lat, lon)[1],
            "heading":    hdg + random.gauss(0, 4),
            "speed_ms":   max(0.0, self.speed_ms + random.gauss(0, 0.2)),
            "crowding":   random.choice(["empty","light","moderate","packed",None]),
            "session_id": f"sim-{self.line_id}-{id(self)}-{i}",
        } for i in range(n)]


def load_wagons() -> list[SimWagon]:
    wagons = []
    files = list(GEOJSON_DIR.glob("*_lines.geojson"))
    if not files:
        logger.error(f"No GeoJSON in {GEOJSON_DIR}"); return wagons

    for gf in files:
        is_metro = "metro_lines" in gf.name
        cruise   = METRO_SPEED_MS if is_metro else BUS_SPEED_MS
        try:
            features = json.loads(gf.read_text()).get("features", [])
        except Exception as e:
            logger.warning(f"{gf.name}: {e}"); continue

        by_line: dict[str, list] = {}
        for f in features:
            lid = f.get("properties",{}).get("line_id","unknown")
            by_line.setdefault(lid, []).append(f)

        for line_id, feats in by_line.items():
            route = build_route(feats)
            if len(route) < 2: continue
            length   = route_length(route)
            cap      = MAX_WAGONS.get(line_id, 6)
            n_wagons = min(cap, max(3, int(length / 2500)))
            spacing  = length / n_wagons
            logger.info(f"  {line_id}: {length/1000:.1f}km → {n_wagons} wagons")
            for i in range(n_wagons):
                w = SimWagon(line_id, route, cruise, i*spacing, 1 if i%2==0 else -1)
                # Seed initial passengers (2–6)
                for _ in range(random.randint(2, 6)):
                    w.passengers.append(Passenger())
                wagons.append(w)

    logger.info(f"✅ {len(wagons)} wagons")
    return wagons


async def run_simulation(db_factory):
    wagons = load_wagons()
    if not wagons:
        logger.warning("No routes"); return

    from sqlalchemy import text as sa_text
    from app.routers.vehicles import aggregate_and_broadcast

    while True:
        t0 = asyncio.get_event_loop().time()
        for w in wagons:
            w.step(REPORT_INTERVAL)

        reports = [r for w in wagons for r in w.get_reports()]
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
                for lid in {r["line_id"] for r in reports}:
                    await aggregate_and_broadcast(lid, db)

        await asyncio.sleep(max(0.1, REPORT_INTERVAL-(asyncio.get_event_loop().time()-t0)))
EOF

# ── 3. BACKEND: pass passenger count in cluster output ───────────────────
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

# Speed thresholds — made more dramatic
SPEED_NORMAL_MS  = 5.0   # > green
SPEED_SLOW_MS    = 2.5   # > amber, else red


def haversine_m(lat1, lon1, lat2, lon2) -> float:
    R = 6_371_000
    φ1, φ2 = radians(lat1), radians(lat2)
    dφ, dλ = radians(lat2-lat1), radians(lon2-lon1)
    a = sin(dφ/2)**2 + cos(φ1)*cos(φ2)*sin(dλ/2)**2
    return R * 2 * atan2(sqrt(a), sqrt(1-a))


def speed_status(s):
    if s is None:         return "normal"
    if s >= SPEED_NORMAL_MS: return "normal"
    if s >= SPEED_SLOW_MS:   return "slow"
    return "stopped"


def cluster_reports(rows) -> list[dict]:
    points = [{"lat":r.lat,"lon":r.lon,"heading":r.heading,"speed":r.speed,"crowding":r.crowding}
              for r in rows if r.lat is not None]
    if not points: return []

    clusters, assigned = [], [False]*len(points)
    for i, p in enumerate(points):
        if assigned[i]: continue
        cl = [p]; assigned[i] = True
        for j, q in enumerate(points):
            if assigned[j]: continue
            if haversine_m(p["lat"],p["lon"],q["lat"],q["lon"]) <= CLUSTER_RADIUS_M:
                cl.append(q); assigned[j] = True
        clusters.append(cl)

    result = []
    for cl in clusters:
        n      = len(cl)
        lats   = [p["lat"] for p in cl]
        lons   = [p["lon"] for p in cl]
        heads  = [p["heading"] for p in cl if p["heading"] is not None]
        speeds = [p["speed"]   for p in cl if p["speed"]   is not None]
        crowds = [p["crowding"] for p in cl if p["crowding"]]
        avg_spd = sum(speeds)/len(speeds) if speeds else None
        result.append({
            "latitude":     sum(lats)/n,
            "longitude":    sum(lons)/n,
            "heading":      sum(heads)/len(heads) if heads else None,
            "speed_ms":     avg_spd,
            "speed_status": speed_status(avg_spd),
            "crowding":     max(set(crowds),key=crowds.count) if crowds else None,
            "passengers":   n,   # reporter count = passengers
        })
    return result


@router.post("/report")
async def submit_report(report: VehicleReportCreate, db: AsyncSession = Depends(get_db)):
    db.add(VehicleReport(
        line_id=report.line_id, session_id=report.session_id,
        latitude=report.latitude, longitude=report.longitude,
        heading=report.heading, speed_ms=report.speed_ms,
        crowding=report.crowding.value if report.crowding else None,
    ))
    await db.commit()
    await aggregate_and_broadcast(report.line_id, db)
    return {"status":"ok"}


@router.get("/{line_id}")
async def get_vehicles(line_id: str, db: AsyncSession = Depends(get_db)):
    return cluster_reports(await _fetch_recent(line_id, db))


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await hub.connect(websocket)
    try:
        while True:
            msg = WSMessage(**json.loads(await websocket.receive_text()))
            if msg.type == WSMessageType.subscribe:
                await hub.subscribe(websocket, msg.payload["line_id"])
            elif msg.type == WSMessageType.unsubscribe:
                await hub.unsubscribe(websocket, msg.payload["line_id"])
    except WebSocketDisconnect:
        await hub.disconnect(websocket)


async def _fetch_recent(line_id, db):
    cutoff = datetime.now(UTC) - timedelta(minutes=WINDOW_MINUTES)
    r = await db.execute(
        text("SELECT latitude AS lat,longitude AS lon,heading,speed_ms AS speed,crowding "
             "FROM vehicle_reports WHERE line_id=:l AND reported_at>:c"),
        {"l":line_id,"c":cutoff}
    )
    return r.fetchall()


async def aggregate_and_broadcast(line_id, db):
    vs = cluster_reports(await _fetch_recent(line_id, db))
    if vs:
        await hub.broadcast_to_line(line_id, {
            "type":"vehicle_update",
            "payload":{"lineId":line_id,"vehicles":vs,
                       "updatedAt":datetime.now(UTC).isoformat()}
        })
EOF

echo "✅ Done! Run: docker compose restart backend"
