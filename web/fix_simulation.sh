#!/usr/bin/env bash
# Fix simulation: realistic wagon counts, 0-10 random reporters, speed-based colors

# ── 1. SIMULATION: realistic wagons + variable reporters ─────────────────
cat > backend/app/tasks/simulation.py << 'EOF'
"""
Realistic CDMX transit simulation.
- Capped wagon counts per line (based on real operations)
- 0–10 random reporters per wagon (some wagons are "invisible")
- Speed varies naturally: acceleration, cruise, deceleration at stops
- Speed state fed to frontend for color coding
"""
import asyncio, json, math, random, logging
from pathlib import Path

logger = logging.getLogger(__name__)

GEOJSON_DIR     = Path("/app/geojson")
REPORT_INTERVAL = 8       # seconds between ticks
NOISE_M         = 18      # GPS noise metres
METRO_SPEED_MS  = 9.5     # ~34 km/h cruise
BUS_SPEED_MS    = 5.5     # ~20 km/h cruise
STOP_DWELL_S    = 25      # seconds stopped at each station

# Real CDMX peak train counts (approximate simultaneous trains per direction × 2)
MAX_WAGONS = {
    "metro-1": 18, "metro-2": 18, "metro-3": 18, "metro-4": 10,
    "metro-5": 14, "metro-6": 10, "metro-7": 14, "metro-8": 14,
    "metro-9": 14, "metro-a": 12, "metro-b": 16, "metro-12": 14,
    "metrobus-1": 22, "metrobus-2": 16, "metrobus-3": 18,
    "metrobus-4": 14, "metrobus-5": 8,  "metrobus-6": 12, "metrobus-7": 12,
}


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


def add_noise(lat, lon, radius_m=NOISE_M):
    r = radius_m / 111_320
    a = random.uniform(0, 2*math.pi)
    return lat + r*math.sin(a), lon + r*math.cos(a)


def route_length(route) -> float:
    return sum(haversine_m(*route[i], *route[i+1]) for i in range(len(route)-1))


def build_route(features: list) -> list[tuple[float,float]]:
    segs = [f["geometry"]["coordinates"]
            for f in features if f.get("geometry",{}).get("type")=="LineString"]
    if not segs:
        return []
    result = list(segs[0])
    for seg in segs[1:]:
        if not seg: continue
        d_ff = haversine_m(result[-1][1],result[-1][0], seg[0][1],  seg[0][0])
        d_fr = haversine_m(result[-1][1],result[-1][0], seg[-1][1], seg[-1][0])
        if d_fr < d_ff: seg = list(reversed(seg))
        gap = haversine_m(result[-1][1],result[-1][0], seg[0][1], seg[0][0])
        if gap < 3000:
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


class SimWagon:
    def __init__(self, line_id, route, cruise_ms, offset_m, direction):
        self.line_id    = line_id
        self.route      = route
        self.cruise_ms  = cruise_ms * random.uniform(0.9, 1.1)
        self.length     = route_length(route)
        self.position   = offset_m % self.length
        self.direction  = direction
        self.speed_ms   = cruise_ms  # current speed
        self.dwell_left = 0          # seconds remaining at stop
        self._phase     = random.uniform(0, math.pi*2)  # for speed oscillation

        # Re-randomize reporter count each tick (0–10)
        self.reporters  = 0

    def step(self, dt_s):
        # Re-roll reporters each cycle (0 = wagon not visible this tick)
        self.reporters = random.choices(
            range(11),
            weights=[8, 10, 12, 14, 14, 12, 10, 8, 6, 4, 2]  # 0 most likely, 10 rare
        )[0]

        # Dwell at terminal
        if self.dwell_left > 0:
            self.dwell_left -= dt_s
            self.speed_ms = 0
            return

        # Speed oscillation simulating acceleration/deceleration between stops
        self._phase += dt_s * 0.08  # one full cycle every ~78s ≈ station spacing
        speed_factor = 0.5 + 0.5 * abs(math.sin(self._phase))
        # Add small random jitter (delays, signal holds)
        speed_factor *= random.uniform(0.85, 1.05)
        self.speed_ms = self.cruise_ms * speed_factor

        self.position += self.speed_ms * self.direction * dt_s

        if self.position >= self.length:
            self.position = self.length - (self.position - self.length)
            self.direction = -1
            self.dwell_left = STOP_DWELL_S
            self.speed_ms = 0
        elif self.position <= 0:
            self.position = abs(self.position)
            self.direction = 1
            self.dwell_left = STOP_DWELL_S
            self.speed_ms = 0

    def get_reports(self):
        if self.reporters == 0:
            return []   # wagon has no active reporters this tick
        route = self.route if self.direction == 1 else list(reversed(self.route))
        pos   = self.position if self.direction == 1 else self.length - self.position
        lat, lon, hdg = sample_at(route, pos)
        return [{
            "line_id":    self.line_id,
            "latitude":   add_noise(lat, lon)[0],
            "longitude":  add_noise(lat, lon)[1],
            "heading":    hdg + random.gauss(0, 5),
            "speed_ms":   max(0, self.speed_ms + random.gauss(0, 0.3)),
            "crowding":   random.choice(["empty","light","moderate","packed", None]),
            "session_id": f"sim-{self.line_id}-{id(self)}-{i}",
        } for i in range(self.reporters)]


def load_wagons() -> list[SimWagon]:
    wagons = []
    files = list(GEOJSON_DIR.glob("*_lines.geojson"))
    if not files:
        logger.error(f"No GeoJSON files in {GEOJSON_DIR}")
        return wagons

    for geojson_file in files:
        is_metro = "metro_lines" in geojson_file.name
        cruise   = METRO_SPEED_MS if is_metro else BUS_SPEED_MS
        try:
            data     = json.loads(geojson_file.read_text())
            features = data.get("features", [])
        except Exception as e:
            logger.warning(f"{geojson_file.name}: {e}")
            continue

        by_line: dict[str, list] = {}
        for f in features:
            lid = f.get("properties", {}).get("line_id", "unknown")
            by_line.setdefault(lid, []).append(f)

        for line_id, feats in by_line.items():
            route = build_route(feats)
            if len(route) < 2:
                continue
            length   = route_length(route)
            cap      = MAX_WAGONS.get(line_id, 12)
            n_wagons = min(cap, max(4, int(length / 2000)))  # at most 1 per 2km, capped
            spacing  = length / n_wagons
            logger.info(f"  {line_id}: {length/1000:.1f}km → {n_wagons} wagons")
            for i in range(n_wagons):
                wagons.append(SimWagon(
                    line_id, route, cruise,
                    offset_m  = i * spacing,
                    direction = 1 if i % 2 == 0 else -1,
                ))

    total = len(wagons)
    logger.info(f"✅ {total} wagons loaded")
    return wagons


async def run_simulation(db_factory):
    wagons = load_wagons()
    if not wagons:
        logger.warning("Simulation idle — no routes found")
        return

    from sqlalchemy import text as sa_text
    from app.routers.vehicles import aggregate_and_broadcast

    while True:
        t0 = asyncio.get_event_loop().time()

        for w in wagons:
            w.step(REPORT_INTERVAL)

        reports = [r for w in wagons for r in w.get_reports()]

        if reports:
            async with db_factory() as db:
                await db.execute(
                    sa_text("""
                        INSERT INTO vehicle_reports
                            (id, line_id, session_id, latitude, longitude,
                             heading, speed_ms, crowding, reported_at)
                        VALUES
                            (gen_random_uuid(), :line_id, :session_id,
                             :latitude, :longitude, :heading, :speed_ms,
                             :crowding, NOW())
                    """),
                    reports,
                )
                await db.commit()
                for line_id in {r["line_id"] for r in reports}:
                    await aggregate_and_broadcast(line_id, db)

        await asyncio.sleep(max(0.1, REPORT_INTERVAL - (asyncio.get_event_loop().time() - t0)))
EOF

# ── 2. BACKEND: include avg_speed in cluster output ──────────────────────
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

# Speed thresholds (m/s)
SPEED_NORMAL_MS = 6.0   # above → green
SPEED_SLOW_MS   = 3.0   # above → yellow, below → red


def haversine_m(lat1, lon1, lat2, lon2) -> float:
    R = 6_371_000
    φ1, φ2 = radians(lat1), radians(lat2)
    dφ, dλ = radians(lat2-lat1), radians(lon2-lon1)
    a = sin(dφ/2)**2 + cos(φ1)*cos(φ2)*sin(dλ/2)**2
    return R * 2 * atan2(sqrt(a), sqrt(1-a))


def speed_status(speed_ms: float | None) -> str:
    if speed_ms is None: return "normal"
    if speed_ms >= SPEED_NORMAL_MS: return "normal"
    if speed_ms >= SPEED_SLOW_MS:   return "slow"
    return "stopped"


def cluster_reports(rows) -> list[dict]:
    points = [{"lat": r.lat, "lon": r.lon, "heading": r.heading,
               "speed": r.speed, "crowding": r.crowding}
              for r in rows if r.lat is not None]
    if not points:
        return []

    clusters, assigned = [], [False]*len(points)
    for i, p in enumerate(points):
        if assigned[i]: continue
        cluster = [p]; assigned[i] = True
        for j, q in enumerate(points):
            if assigned[j]: continue
            if haversine_m(p["lat"], p["lon"], q["lat"], q["lon"]) <= CLUSTER_RADIUS_M:
                cluster.append(q); assigned[j] = True
        clusters.append(cluster)

    vehicles = []
    for cl in clusters:
        n      = len(cl)
        lats   = [p["lat"]  for p in cl]
        lons   = [p["lon"]  for p in cl]
        heads  = [p["heading"] for p in cl if p["heading"] is not None]
        speeds = [p["speed"]   for p in cl if p["speed"]   is not None]
        crowds = [p["crowding"] for p in cl if p["crowding"]]
        avg_speed = sum(speeds)/len(speeds) if speeds else None
        vehicles.append({
            "latitude":     sum(lats)/n,
            "longitude":    sum(lons)/n,
            "heading":      sum(heads)/len(heads) if heads else None,
            "speed_ms":     avg_speed,
            "speed_status": speed_status(avg_speed),
            "crowding":     max(set(crowds), key=crowds.count) if crowds else None,
            "report_count": n,
        })
    return vehicles


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
    return {"status": "ok"}


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


async def _fetch_recent(line_id: str, db: AsyncSession):
    cutoff = datetime.now(UTC) - timedelta(minutes=WINDOW_MINUTES)
    result = await db.execute(
        text("SELECT latitude AS lat, longitude AS lon, heading, speed_ms AS speed, crowding "
             "FROM vehicle_reports WHERE line_id=:l AND reported_at>:c"),
        {"l": line_id, "c": cutoff}
    )
    return result.fetchall()


async def aggregate_and_broadcast(line_id: str, db: AsyncSession):
    vehicles = cluster_reports(await _fetch_recent(line_id, db))
    if vehicles:
        await hub.broadcast_to_line(line_id, {
            "type": "vehicle_update",
            "payload": {"lineId": line_id, "vehicles": vehicles,
                        "updatedAt": datetime.now(UTC).isoformat()}
        })
EOF

# ── 3. FRONTEND: speed-based colors ──────────────────────────────────────
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

// Speed status → dot color
const STATUS_COLOR: Record<string, string> = {
  normal:  '#22c55e',   // green
  slow:    '#f59e0b',   // amber
  stopped: '#ef4444',   // red
}

export default function App() {
  const containerRef = useRef<HTMLDivElement>(null)
  const map          = useRef<mapboxgl.Map | null>(null)
  const ws           = useRef<WebSocket | null>(null)
  const vehicles     = useRef<Record<string, any[]>>({})
  const [ready, setReady] = useState(false)

  // ── Map init ─────────────────────────────────────────────────────────
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

  // ── Layer setup ───────────────────────────────────────────────────────
  const initLayers = useCallback(async (m: mapboxgl.Map) => {
    const load = async (url: string) => {
      const r = await fetch(url)
      if (!r.ok) throw new Error(`${url} ${r.status}`)
      return r.json()
    }
    try {
      const [metroLines, metroStops, mbLines, mbStops] = await Promise.all([
        load('/geojson/metro_lines.geojson'),
        load('/geojson/metro_stops.geojson'),
        load('/geojson/metrobus_lines.geojson').catch(() => ({type:'FeatureCollection',features:[]})),
        load('/geojson/metrobus_stops.geojson').catch(() => ({type:'FeatureCollection',features:[]})),
      ])

      for (const [srcId, data, w] of [
        ['metro-lines',    metroLines, 4],
        ['metrobus-lines', mbLines,    3],
      ] as [string, any, number][]) {
        m.addSource(srcId, { type:'geojson', data })
        m.addLayer({ id:`${srcId}-casing`, type:'line', source:srcId,
          layout: { 'line-cap':'round', 'line-join':'round' },
          paint:  { 'line-color':'#000', 'line-width':w+3, 'line-opacity':0.5 } })
        m.addLayer({ id:`${srcId}-fill`, type:'line', source:srcId,
          layout: { 'line-cap':'round', 'line-join':'round' },
          paint:  { 'line-color':['get','line_color'], 'line-width':w, 'line-opacity':0.95 } })
      }

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
          layout: { 'text-field':['get','stop_name'], 'text-size':10, 'text-offset':[0,1.4], 'text-anchor':'top', 'text-optional':true },
          paint:  { 'text-color':'#fff', 'text-halo-color':'#000', 'text-halo-width':1.2 }
        })
        m.on('mouseenter', `${srcId}-circle`, () => m.getCanvas().style.cursor = 'pointer')
        m.on('mouseleave', `${srcId}-circle`, () => m.getCanvas().style.cursor = '')
        m.on('click', `${srcId}-circle`, (e) => {
          const p = e.features?.[0]?.properties as any
          if (!p) return
          const line = lineById(p.line_id)
          new mapboxgl.Popup({ closeButton:false, offset:8 })
            .setLngLat(e.lngLat)
            .setHTML(`<div style="font:13px/1.4 system-ui;padding:4px 8px">
              <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??''}</span>
              <div style="font-weight:600;margin-top:5px">${p.stop_name}</div>
            </div>`).addTo(m)
        })
      }

      // Vehicle source — color comes from speed_status property
      m.addSource('vehicles', { type:'geojson', data:{type:'FeatureCollection',features:[]} })

      // Outer glow (line color)
      m.addLayer({ id:'vehicle-glow', type:'circle', source:'vehicles',
        paint: {
          'circle-radius':  ['interpolate',['linear'],['zoom'],10,18,15,30],
          'circle-color':   ['get','line_color'],
          'circle-opacity': 0.15,
        }
      })

      // Main dot (speed color)
      m.addLayer({ id:'vehicle-dot', type:'circle', source:'vehicles',
        paint: {
          'circle-radius': ['interpolate',['linear'],['zoom'],10,7,15,14],
          'circle-color':  ['get','speed_color'],
          'circle-stroke-color': '#fff',
          'circle-stroke-width': 2.5,
        }
      })

      // Reporter count badge
      m.addLayer({ id:'vehicle-label', type:'symbol', source:'vehicles',
        minzoom: 10,
        layout: {
          'text-field': ['case',
            ['>', ['get','report_count'], 0],
            ['to-string', ['get','report_count']],
            ''
          ],
          'text-size': 10,
          'text-font': ['DIN Offc Pro Bold','Arial Unicode MS Bold'],
        },
        paint: { 'text-color':'#fff' }
      })

      // Click popup on vehicle
      m.on('mouseenter', 'vehicle-dot', () => m.getCanvas().style.cursor = 'pointer')
      m.on('mouseleave', 'vehicle-dot', () => m.getCanvas().style.cursor = '')
      m.on('click', 'vehicle-dot', (e) => {
        const p = e.features?.[0]?.properties as any
        if (!p) return
        const line = lineById(p.line_id)
        const speed_kmh = p.speed_ms ? (p.speed_ms * 3.6).toFixed(0) : '—'
        const statusLabel = { normal:'Normal ✅', slow:'Lento ⚠️', stopped:'Detenido 🔴' }[p.speed_status as string] ?? ''
        new mapboxgl.Popup({ closeButton:false, offset:12 })
          .setLngLat((e.features![0].geometry as any).coordinates)
          .setHTML(`<div style="font:13px/1.6 system-ui;padding:4px 8px;min-width:140px">
            <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??p.line_id}</span>
            <div style="margin-top:6px"><b>${statusLabel}</b></div>
            <div style="color:#666;font-size:11px">${speed_kmh} km/h · ${p.report_count} reporter${p.report_count!==1?'s':''}</div>
          </div>`).addTo(m)
      })

    } catch(err) { console.warn('Layer init error:', err) }
  }, [])

  // ── Update vehicle GeoJSON ────────────────────────────────────────────
  const updateMap = useCallback(() => {
    if (!map.current) return
    const src = map.current.getSource('vehicles') as mapboxgl.GeoJSONSource
    if (!src) return
    const features: any[] = []
    for (const [lineId, clusters] of Object.entries(vehicles.current)) {
      const line = lineById(lineId)
      for (const v of clusters) {
        features.push({
          type: 'Feature',
          geometry: { type:'Point', coordinates:[v.longitude, v.latitude] },
          properties: {
            line_id:      lineId,
            line_color:   line?.colorHex ?? '#fff',
            speed_color:  STATUS_COLOR[v.speed_status ?? 'normal'],
            speed_ms:     v.speed_ms,
            speed_status: v.speed_status ?? 'normal',
            report_count: v.report_count,
            heading:      v.heading ?? 0,
            crowding:     v.crowding ?? '',
          }
        })
      }
    }
    src.setData({ type:'FeatureCollection', features })
  }, [])

  // ── WebSocket ─────────────────────────────────────────────────────────
  useEffect(() => {
    if (!ready) return
    const connect = () => {
      const socket = new WebSocket(WS_URL)
      ws.current = socket
      socket.onopen = () => {
        ALL_LINE_IDS.forEach(id =>
          socket.send(JSON.stringify({ type:'subscribe', payload:{ line_id:id } }))
        )
      }
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

echo "✅ Done! Restart with: docker compose restart backend"
