#!/usr/bin/env bash

# ── 1. SIMULATION: pre-computed stop positions + proper physics ──────────
cat > backend/app/tasks/simulation.py << 'EOF'
import asyncio, json, math, random, logging, uuid
from pathlib import Path

logger      = logging.getLogger(__name__)
GEOJSON_DIR = Path("/app/geojson")

TICK_S        = 2          # broadcast interval
METRO_MAX_MS  = 25.0       # 90 km/h
BUS_MAX_MS    = 13.9       # 50 km/h
METRO_ACCEL   = 1.1        # m/s²  acceleration
METRO_DECEL   = 1.6        # m/s²  braking (harder than accel)
BUS_ACCEL     = 0.65
BUS_DECEL     = 1.0
DWELL_S       = 7.0        # seconds stopped at every station
NOISE_M       = 6          # GPS noise

# Station spacing: metro ~900m, bus ~400m between stops
METRO_STOP_SPACING = 900
BUS_STOP_SPACING   = 400

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

def compute_stops(length, spacing):
    """Pre-compute evenly-spaced station positions along route (in metres)."""
    n = max(2, int(length / spacing))
    return [i * length / n for i in range(n)]

def sample_at(route, dist_m):
    """Return (lat, lon, heading) — heading averaged with next segment for smoothness."""
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
                hdg=(hdg+frac*diff)%360
            return lat,lon,hdg
        walked+=seg
    return route[-1][0],route[-1][1],0.0

def in_busy_zone(lat,lon):
    for zlat,zlon,zr in BUSY_ZONES:
        d=haversine_m(lat,lon,zlat,zlon)
        if d<zr: return 1.0-(d/zr)
    return 0.0

def braking_distance(speed, decel):
    """Metres needed to stop from `speed` at `decel` m/s²."""
    return (speed*speed)/(2*decel)


class SimWagon:
    def __init__(self, line_id, route, max_ms, accel, decel, stop_positions, offset_m, direction):
        self.wagon_id      = f"{line_id}-{str(uuid.uuid4())[:8]}"
        self.line_id       = line_id
        self.route         = route
        self.length        = route_length(route)
        self.max_ms        = max_ms * random.uniform(0.90, 1.0)
        self.accel         = accel
        self.decel         = decel
        self.stops         = stop_positions   # sorted list of distances along route
        self.position      = offset_m % self.length
        self.direction     = direction
        self.speed_ms      = 0.0
        self.dwell_left    = random.uniform(0, 15)  # stagger cold starts
        self.passengers    = random.randint(0, 10)
        self._at_stop      = False

    def _next_stop_dist(self):
        """Distance to the nearest upcoming stop in current direction of travel."""
        pos = self.position
        if self.direction == 1:
            ahead = [s for s in self.stops if s > pos]
            return (ahead[0] - pos) if ahead else (self.length - pos)
        else:
            behind = [s for s in self.stops if s < pos]
            return (pos - behind[-1]) if behind else pos

    def step(self, dt_s):
        # ── Dwelling at station ───────────────────────────────────────
        if self.dwell_left > 0:
            self.dwell_left = max(0.0, self.dwell_left - dt_s)
            self.speed_ms   = 0.0
            self._at_stop   = True
            return
        self._at_stop = False

        # ── Busy zone congestion factor ───────────────────────────────
        lat, lon, _ = sample_at(self.route, self.position)
        busy        = in_busy_zone(lat, lon)
        # Congestion caps max speed (red zones really slow things down)
        effective_max = self.max_ms * max(0.05, 1.0 - busy * 0.80)

        # ── Compute target speed based on distance to next stop ───────
        d_to_stop = self._next_stop_dist()
        # Distance needed to brake to 0 from current speed
        d_brake   = braking_distance(self.speed_ms, self.decel)

        if d_to_stop <= 0.5:
            # Arrived at stop
            self.speed_ms   = 0.0
            self.dwell_left = DWELL_S
            if busy > 0.4:
                self.dwell_left += busy * 8   # longer dwell in busy zones
            # Passenger churn
            alight = random.randint(0, min(self.passengers, 5))
            board  = random.randint(0, min(10 - max(0, self.passengers - alight),
                                           int(2 + busy * 6)))
            self.passengers = max(0, min(10, self.passengers - alight + board))
            return

        if d_brake >= d_to_stop * 0.95:
            # Need to brake NOW
            target = max(0.0, math.sqrt(max(0.0, 2.0 * self.decel * d_to_stop)))
            target = min(target, effective_max)
        else:
            # Accelerate toward cruise speed
            target = effective_max

        # Smooth speed change
        if self.speed_ms < target:
            self.speed_ms = min(target, self.speed_ms + self.accel * dt_s)
        elif self.speed_ms > target:
            self.speed_ms = max(target, self.speed_ms - self.decel * dt_s)

        # ── Move ──────────────────────────────────────────────────────
        delta         = self.speed_ms * dt_s
        self.position += self.direction * delta

        # Terminal bounce
        if self.position >= self.length:
            self.position   = self.length - (self.position - self.length)
            self.direction  = -1
            self.speed_ms   = 0.0
            self.dwell_left = DWELL_S
            self.passengers = random.randint(0, 5)
        elif self.position <= 0:
            self.position   = abs(self.position)
            self.direction  = 1
            self.speed_ms   = 0.0
            self.dwell_left = DWELL_S
            self.passengers = random.randint(0, 5)

    def speed_status(self):
        if self._at_stop or self.speed_ms < 1.0:
            return "stopped"
        elif self.speed_ms < self.max_ms * 0.45:
            return "slow"
        return "normal"

    def get_report(self):
        route = self.route if self.direction == 1 else list(reversed(self.route))
        pos   = self.position if self.direction == 1 else self.length - self.position
        lat, lon, hdg = sample_at(route, pos)
        nlat, nlon    = add_noise(lat, lon)
        return {
            "line_id":    self.line_id,
            "session_id": self.wagon_id,
            "latitude":   nlat,
            "longitude":  nlon,
            "heading":    (hdg + random.gauss(0, 1.5)) % 360,
            "speed_ms":   self.speed_ms,
            "crowding":   ("packed"   if self.passengers > 7 else
                           "moderate" if self.passengers > 4 else
                           "light"    if self.passengers > 1 else "empty"),
            "passengers": self.passengers,
        }


def load_wagons():
    wagons = []
    for gf in GEOJSON_DIR.glob("*_lines.geojson"):
        is_metro = "metro_lines" in gf.name
        max_ms   = METRO_MAX_MS   if is_metro else BUS_MAX_MS
        accel    = METRO_ACCEL    if is_metro else BUS_ACCEL
        decel    = METRO_DECEL    if is_metro else BUS_DECEL
        spacing  = METRO_STOP_SPACING if is_metro else BUS_STOP_SPACING
        try:
            features = json.loads(gf.read_text()).get("features", [])
        except Exception as e:
            logger.warning(f"{gf.name}: {e}"); continue

        by_line: dict[str, list] = {}
        for f in features:
            lid = f.get("properties", {}).get("line_id", "unknown")
            by_line.setdefault(lid, []).append(f)

        for line_id, feats in by_line.items():
            route = build_route(feats)
            if len(route) < 2: continue
            length     = route_length(route)
            stops      = compute_stops(length, spacing)
            cap        = MAX_WAGONS.get(line_id, 6)
            n_wagons   = min(cap, max(3, int(length / 3000)))
            wagon_gap  = length / n_wagons
            logger.info(f"  {line_id}: {length/1000:.1f}km, {len(stops)} stops → {n_wagons} wagons")

            for i in range(n_wagons):
                wagons.append(SimWagon(
                    line_id, route, max_ms, accel, decel, stops,
                    offset_m  = i * wagon_gap + random.uniform(-80, 80),
                    direction = 1 if i % 2 == 0 else -1,
                ))

    logger.info(f"✅ {len(wagons)} wagons loaded")
    return wagons


async def run_simulation(db_factory):
    wagons = load_wagons()
    if not wagons:
        logger.warning("No routes found"); return

    from sqlalchemy import text as sa_text
    from app.routers.vehicles import broadcast_wagons_direct

    while True:
        t0 = asyncio.get_event_loop().time()

        for w in wagons:
            w.step(TICK_S)

        # Group by line and broadcast
        by_line: dict[str, list] = {}
        reports = []
        for w in wagons:
            r = w.get_report()
            by_line.setdefault(w.line_id, []).append({
                "wagon_id":    w.wagon_id,
                "latitude":    r["latitude"],
                "longitude":   r["longitude"],
                "heading":     r["heading"],
                "speed_ms":    r["speed_ms"],
                "speed_status":w.speed_status(),
                "passengers":  w.passengers,
            })
            reports.append(r)

        if reports:
            async with db_factory() as db:
                await db.execute(sa_text("""
                    INSERT INTO vehicle_reports
                        (id,line_id,session_id,latitude,longitude,
                         heading,speed_ms,crowding,reported_at)
                    VALUES (gen_random_uuid(),:line_id,:session_id,:latitude,:longitude,
                            :heading,:speed_ms,:crowding,NOW())
                """), reports)
                await db.commit()

        for line_id, vehicles in by_line.items():
            await broadcast_wagons_direct(line_id, vehicles)

        elapsed = asyncio.get_event_loop().time() - t0
        await asyncio.sleep(max(0.05, TICK_S - elapsed))
EOF

# ── 2. FRONTEND: fix rotation (-90 offset) + smoother interp ────────────
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

// Speed status → inner color
const STATUS_COLOR: Record<string,string> = {
  normal:  '#22c55e',
  slow:    '#f59e0b',
  stopped: '#ef4444',
}

const INTERP_MS = 2000  // must match backend TICK_S * 1000

interface WagonState {
  wagon_id: string; line_id: string
  fromLng: number; fromLat: number; toLng: number; toLat: number
  fromHdg: number; toHdg:   number
  speed_ms: number; speed_status: string; passengers: number
  startedAt: number
}

const lerp = (a:number, b:number, t:number) => a + (b-a)*t

function lerpAngle(a: number, b: number, t: number) {
  const diff = ((b - a + 180) % 360) - 180
  return (a + diff * t + 360) % 360
}

function easeInOut(t: number) {
  return t < 0.5 ? 4*t*t*t : 1 - Math.pow(-2*t+2, 3)/2
}

/**
 * Draw wagon sprite with VERTICAL long axis.
 * Mapbox icon-rotate:0 = pointing north.
 * Our sprite long axis = vertical → when heading=0 (north) the wagon
 * faces the right direction without any offset needed.
 */
function makeSprite(type: 'metro'|'metrobus', statusColor: string, size = 64) {
  const c   = document.createElement('canvas')
  c.width   = size; c.height = size
  const ctx = c.getContext('2d')!

  // Metro: tall narrow capsule  |  Metrobús: shorter wider box
  const isMetro = type === 'metro'
  const w = isMetro ? size * 0.32 : size * 0.40
  const h = isMetro ? size * 0.88 : size * 0.55
  const x = (size - w) / 2
  const y = (size - h) / 2
  const r = w / 2   // corner radius = half-width for full capsule ends

  // Shadow
  ctx.shadowColor   = 'rgba(0,0,0,0.55)'
  ctx.shadowBlur    = 6
  ctx.shadowOffsetY = 2

  // Body
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.lineTo(x + w - r, y)
  ctx.quadraticCurveTo(x + w, y,       x + w, y + r)
  ctx.lineTo(x + w, y + h - r)
  ctx.quadraticCurveTo(x + w, y + h,   x + w - r, y + h)
  ctx.lineTo(x + r, y + h)
  ctx.quadraticCurveTo(x,     y + h,   x, y + h - r)
  ctx.lineTo(x,     y + r)
  ctx.quadraticCurveTo(x,     y,       x + r, y)
  ctx.closePath()
  ctx.fillStyle = statusColor
  ctx.fill()

  // Window strip (horizontal band across middle)
  ctx.shadowColor = 'transparent'
  ctx.fillStyle   = 'rgba(255,255,255,0.22)'
  ctx.fillRect(x + w*0.15, y + h*0.35, w*0.70, h*0.28)

  // Border
  ctx.strokeStyle = 'rgba(255,255,255,0.85)'
  ctx.lineWidth   = 1.8
  ctx.stroke()

  return ctx.getImageData(0, 0, size, size)
}

export default function App() {
  const containerRef = useRef<HTMLDivElement>(null)
  const map          = useRef<mapboxgl.Map|null>(null)
  const ws           = useRef<WebSocket|null>(null)
  const rafId        = useRef<number>(0)
  const [ready, setReady] = useState(false)
  // Keyed by wagon_id — never re-keyed
  const stateRef = useRef<Map<string, WagonState>>(new Map())

  useEffect(() => {
    if (map.current || !containerRef.current) return
    const m = new mapboxgl.Map({
      container: containerRef.current,
      style: 'mapbox://styles/mapbox/dark-v11',
      center: [-99.1332, 19.4326],
      zoom: 11.2,
      attributionControl: false,
    })
    m.addControl(new mapboxgl.AttributionControl({ compact:true }), 'bottom-right')
    m.on('load', () => { map.current = m; initLayers(m); setReady(true) })
    return () => { m.remove(); map.current = null }
  }, [])

  const initLayers = useCallback(async (m: mapboxgl.Map) => {
    // Register all 6 sprites (2 types × 3 statuses)
    for (const sys of ['metro','metrobus'] as const)
      for (const st of ['normal','slow','stopped'] as const) {
        const d = makeSprite(sys, STATUS_COLOR[st])
        m.addImage(`wagon-${sys}-${st}`, { width:d.width, height:d.height, data:d.data })
      }

    const load = async (url: string) => {
      const r = await fetch(url); if (!r.ok) throw new Error(url); return r.json()
    }
    try {
      const [mL, mS, bL, bS] = await Promise.all([
        load('/geojson/metro_lines.geojson'),
        load('/geojson/metro_stops.geojson'),
        load('/geojson/metrobus_lines.geojson').catch(()=>({type:'FeatureCollection',features:[]})),
        load('/geojson/metrobus_stops.geojson').catch(()=>({type:'FeatureCollection',features:[]})),
      ])

      // Line layers
      for (const [id, data, w] of [
        ['metro-lines',mL,4],['metrobus-lines',bL,3]
      ] as [string,any,number][]) {
        m.addSource(id, { type:'geojson', data })
        m.addLayer({ id:`${id}-casing`, type:'line', source:id,
          layout: { 'line-cap':'round','line-join':'round' },
          paint:  { 'line-color':'#000','line-width':w+3,'line-opacity':0.5 } })
        m.addLayer({ id:`${id}-fill`, type:'line', source:id,
          layout: { 'line-cap':'round','line-join':'round' },
          paint:  { 'line-color':['get','line_color'],'line-width':w,'line-opacity':0.95 } })
      }

      // Stop layers
      for (const [id, data] of [
        ['metro-stops',mS],['metrobus-stops',bS]
      ] as [string,any][]) {
        m.addSource(id, { type:'geojson', data })
        m.addLayer({ id:`${id}-dot`, type:'circle', source:id,
          paint: {
            'circle-color': '#fff',
            'circle-radius': ['interpolate',['linear'],['zoom'],10,2,15,6],
            'circle-stroke-color': ['get','line_color'],
            'circle-stroke-width': ['interpolate',['linear'],['zoom'],10,1,15,3],
          }
        })
        m.addLayer({ id:`${id}-lbl`, type:'symbol', source:id, minzoom:13,
          layout: { 'text-field':['get','stop_name'],'text-size':10,
                    'text-offset':[0,1.3],'text-anchor':'top','text-optional':true },
          paint:  { 'text-color':'#fff','text-halo-color':'#000','text-halo-width':1.2 }
        })
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

      // Vehicle layer — icon-rotate aligns vertical sprite with heading
      m.addSource('vehicles', { type:'geojson', data:{ type:'FeatureCollection', features:[] } })
      m.addLayer({ id:'vehicle-icon', type:'symbol', source:'vehicles',
        layout: {
          'icon-image':              ['get','icon'],
          'icon-size':               ['interpolate',['linear'],['zoom'],9,0.45,12,0.78,15,1.35],
          // Sprite long axis is VERTICAL → heading maps directly to icon-rotate
          'icon-rotate':             ['get','heading'],
          'icon-rotation-alignment': 'map',
          'icon-allow-overlap':      true,
          'icon-ignore-placement':   true,
          'text-field':              ['get','label'],
          'text-size':               10,
          'text-font':               ['DIN Offc Pro Bold','Arial Unicode MS Bold'],
          'text-allow-overlap':      true,
          'text-ignore-placement':   true,
          'text-anchor':             'center',
          'text-rotation-alignment': 'viewport',
        },
        paint: { 'text-color':'#fff','text-halo-color':'rgba(0,0,0,0.5)','text-halo-width':1 }
      })

      m.on('mouseenter','vehicle-icon',()=>m.getCanvas().style.cursor='pointer')
      m.on('mouseleave','vehicle-icon',()=>m.getCanvas().style.cursor='')
      m.on('click','vehicle-icon',(e)=>{
        const p=e.features?.[0]?.properties as any; if(!p) return
        const line=lineById(p.line_id)
        const kmh = (p.speed_ms * 3.6).toFixed(0)
        const lbl: Record<string,string> = {
          normal:'Normal ✅', slow:'Lento ⚠️', stopped:'Detenido 🔴'
        }
        new mapboxgl.Popup({ closeButton:false, offset:14 })
          .setLngLat((e.features![0].geometry as any).coordinates)
          .setHTML(`<div style="font:13px/1.6 system-ui;padding:6px 10px;min-width:160px">
            <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??p.line_id}</span>
            <div style="margin-top:6px;font-weight:700">${lbl[p.speed_status]??'—'}</div>
            <div style="color:#666;font-size:11px">${kmh} km/h · ${p.passengers} pasajero${p.passengers!==1?'s':''}</div>
          </div>`).addTo(m)
      })

    } catch(e) { console.warn('Layer error:', e) }
  }, [])

  // rAF render loop: smooth interpolation every frame
  const renderLoop = useCallback(() => {
    const m   = map.current
    const src = m?.getSource('vehicles') as mapboxgl.GeoJSONSource | undefined
    if (!src) { rafId.current = requestAnimationFrame(renderLoop); return }

    const now      = performance.now()
    const features: GeoJSON.Feature[] = []

    stateRef.current.forEach(v => {
      const raw  = Math.min(1, (now - v.startedAt) / INTERP_MS)
      const t    = easeInOut(raw)
      const lng  = lerp(v.fromLng, v.toLng, t)
      const lat  = lerp(v.fromLat, v.toLat, t)
      const hdg  = lerpAngle(v.fromHdg, v.toHdg, t)
      const line = lineById(v.line_id)
      const isM  = v.line_id.startsWith('metro-') && !v.line_id.startsWith('metrobus-')

      features.push({
        type: 'Feature',
        geometry: { type:'Point', coordinates:[lng, lat] },
        properties: {
          line_id:      v.line_id,
          icon:         `wagon-${isM?'metro':'metrobus'}-${v.speed_status}`,
          heading:      hdg,
          speed_ms:     v.speed_ms,
          speed_status: v.speed_status,
          passengers:   v.passengers,
          label:        v.passengers > 0 ? String(v.passengers) : '',
        }
      })
    })

    src.setData({ type:'FeatureCollection', features })
    rafId.current = requestAnimationFrame(renderLoop)
  }, [])

  // WebSocket: update targets keyed by stable wagon_id
  useEffect(() => {
    if (!ready) return
    rafId.current = requestAnimationFrame(renderLoop)

    const connect = () => {
      const socket = new WebSocket(WS_URL)
      ws.current   = socket

      socket.onopen = () =>
        ALL_LINE_IDS.forEach(id =>
          socket.send(JSON.stringify({ type:'subscribe', payload:{ line_id:id } }))
        )

      socket.onmessage = (e) => {
        const msg = JSON.parse(e.data)
        if (msg.type !== 'vehicle_update') return
        const { lineId, vehicles } = msg.payload
        const now = performance.now()

        ;(vehicles ?? []).forEach((v: any) => {
          const key  = v.wagon_id as string   // always stable
          const prev = stateRef.current.get(key)
          stateRef.current.set(key, {
            wagon_id:    key,
            line_id:     lineId,
            fromLng:     prev?.toLng ?? v.longitude,
            fromLat:     prev?.toLat ?? v.latitude,
            toLng:       v.longitude,
            toLat:       v.latitude,
            fromHdg:     prev?.toHdg ?? (v.heading ?? 0),
            toHdg:       v.heading ?? 0,
            speed_ms:    v.speed_ms ?? 0,
            speed_status:v.speed_status ?? 'normal',
            passengers:  v.passengers ?? 0,
            startedAt:   now,
          })
        })
      }

      socket.onclose = () => setTimeout(connect, 3000)
    }

    connect()
    return () => { cancelAnimationFrame(rafId.current); ws.current?.close() }
  }, [ready, renderLoop])

  return <div ref={containerRef} style={{ width:'100vw', height:'100vh' }} />
}
EOF

echo "✅ Done. Run: docker compose restart backend"
