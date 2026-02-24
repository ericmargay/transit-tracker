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

interface WagonState {
  wagon_id:string; line_id:string
  fromLng:number; fromLat:number; toLng:number; toLat:number
  fromHdg:number; toHdg:number
  speed_ms:number; speed_status:string; passengers:number
  startedAt:number
}

const lerp=(a:number,b:number,t:number)=>a+(b-a)*t
function lerpAngle(a:number,b:number,t:number){
  const diff=((b-a+180)%360)-180
  return (a+diff*t+360)%360
}
function ease(t:number){return t<0.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2}

/**
 * The sprite MUST be drawn TALL (height > width).
 * "Top of canvas" = north = heading 0.
 * Mapbox icon-rotate=heading → top always points in direction of travel → parallel to track.
 *
 * Metro bus:  18 wide x 50 tall  (narrow capsule, like subway car top-down)
 * Metrobus:   22 wide x 36 tall  (wider, shorter bus shape)
 */
function makeSprite(type:'metro'|'metrobus', color:string):ImageData {
  const S=64
  const c=document.createElement('canvas'); c.width=S; c.height=S
  const ctx=c.getContext('2d')!
  const isM=type==='metro'
  const bw=isM?18:22   // SHORT axis (width)
  const bh=isM?50:36   // LONG  axis (height = north/forward direction)
  const bx=(S-bw)/2, by=(S-bh)/2
  const cr=bw/2        // corner radius → capsule ends

  ctx.shadowColor='rgba(0,0,0,0.55)'; ctx.shadowBlur=6; ctx.shadowOffsetY=2

  ctx.beginPath()
  ctx.moveTo(bx+cr,by); ctx.lineTo(bx+bw-cr,by)
  ctx.quadraticCurveTo(bx+bw,by,       bx+bw,by+cr)
  ctx.lineTo(bx+bw,by+bh-cr)
  ctx.quadraticCurveTo(bx+bw,by+bh,    bx+bw-cr,by+bh)
  ctx.lineTo(bx+cr,by+bh)
  ctx.quadraticCurveTo(bx,by+bh,       bx,by+bh-cr)
  ctx.lineTo(bx,by+cr)
  ctx.quadraticCurveTo(bx,by,          bx+cr,by)
  ctx.closePath()
  ctx.fillStyle=color; ctx.fill()

  ctx.shadowColor='transparent'
  ctx.fillStyle='rgba(255,255,255,0.24)'
  ctx.fillRect(bx+3, by+bh*0.30, bw-6, bh*0.28)
  ctx.strokeStyle='rgba(255,255,255,0.88)'; ctx.lineWidth=1.6; ctx.stroke()

  return ctx.getImageData(0,0,S,S)
}

export default function App(){
  const containerRef=useRef<HTMLDivElement>(null)
  const map=useRef<mapboxgl.Map|null>(null)
  const ws=useRef<WebSocket|null>(null)
  const rafId=useRef<number>(0)
  const [ready,setReady]=useState(false)
  const stateRef=useRef<Map<string,WagonState>>(new Map())

  useEffect(()=>{
    if(map.current||!containerRef.current) return
    const m=new mapboxgl.Map({
      container:containerRef.current,
      style:'mapbox://styles/mapbox/dark-v11',
      center:[-99.1332,19.4326], zoom:11.2, attributionControl:false,
    })
    m.addControl(new mapboxgl.AttributionControl({compact:true}),'bottom-right')
    m.on('load',()=>{map.current=m; initLayers(m); setReady(true)})
    return()=>{m.remove(); map.current=null}
  },[])

  const initLayers=useCallback(async(m:mapboxgl.Map)=>{
    for(const sys of['metro','metrobus'] as const)
      for(const st of['normal','slow','stopped'] as const){
        const px=makeSprite(sys,STATUS_COLOR[st])
        m.addImage(`wagon-${sys}-${st}`,{width:px.width,height:px.height,data:px.data})
      }
    const load=(url:string)=>fetch(url).then(r=>{if(!r.ok) throw new Error(url); return r.json()})
    try{
      const [mL,mS,bL,bS]=await Promise.all([
        load('/geojson/metro_lines.geojson'),
        load('/geojson/metro_stops.geojson'),
        load('/geojson/metrobus_lines.geojson').catch(()=>({type:'FeatureCollection',features:[]})),
        load('/geojson/metrobus_stops.geojson').catch(()=>({type:'FeatureCollection',features:[]})),
      ])
      for(const [id,data,w] of[['metro-lines',mL,4],['metrobus-lines',bL,3]] as[string,any,number][]){
        m.addSource(id,{type:'geojson',data})
        m.addLayer({id:`${id}-casing`,type:'line',source:id,
          layout:{'line-cap':'round','line-join':'round'},
          paint:{'line-color':'#000','line-width':w+3,'line-opacity':0.5}})
        m.addLayer({id:`${id}-fill`,type:'line',source:id,
          layout:{'line-cap':'round','line-join':'round'},
          paint:{'line-color':['get','line_color'],'line-width':w,'line-opacity':0.95}})
      }
      for(const [id,data] of[['metro-stops',mS],['metrobus-stops',bS]] as[string,any][]){
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
        m.on('click',`${id}-dot`,e=>{
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
          'icon-size':              ['interpolate',['linear'],['zoom'],9,0.55,12,0.85,15,1.4],
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
        paint:{'text-color':'#fff','text-halo-color':'rgba(0,0,0,0.6)','text-halo-width':1}
      })
      m.on('mouseenter','vehicle-icon',()=>m.getCanvas().style.cursor='pointer')
      m.on('mouseleave','vehicle-icon',()=>m.getCanvas().style.cursor='')
      m.on('click','vehicle-icon',e=>{
        const p=e.features?.[0]?.properties as any; if(!p) return
        const line=lineById(p.line_id)
        const kmh=(p.speed_ms*3.6).toFixed(0)
        const lbl:Record<string,string>={normal:'Normal ✅',slow:'Lento ⚠️',stopped:'Detenido 🔴'}
        new mapboxgl.Popup({closeButton:false,offset:16})
          .setLngLat((e.features![0].geometry as any).coordinates)
          .setHTML(`<div style="font:13px/1.6 system-ui;padding:6px 10px;min-width:160px">
            <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??p.line_id}</span>
            <div style="margin-top:6px;font-weight:700">${lbl[p.speed_status]??'—'}</div>
            <div style="color:#666;font-size:11px">${kmh} km/h · ${p.passengers} pasajero${p.passengers!==1?'s':''}</div>
          </div>`).addTo(m)
      })
    }catch(err){console.error('Layer error:',err)}
  },[])

  const renderLoop=useCallback(()=>{
    const src=map.current?.getSource('vehicles') as mapboxgl.GeoJSONSource|undefined
    if(!src){rafId.current=requestAnimationFrame(renderLoop); return}
    const now=performance.now()
    const features:GeoJSON.Feature[]=[]
    stateRef.current.forEach(v=>{
      const t=ease(Math.min(1,(now-v.startedAt)/INTERP_MS))
      const lng=lerp(v.fromLng,v.toLng,t)
      const lat=lerp(v.fromLat,v.toLat,t)
      const hdg=lerpAngle(v.fromHdg,v.toHdg,t)
      const isM=v.line_id.startsWith('metro-')&&!v.line_id.startsWith('metrobus-')
      features.push({
        type:'Feature',
        geometry:{type:'Point',coordinates:[lng,lat]},
        properties:{
          line_id:v.line_id,
          icon:`wagon-${isM?'metro':'metrobus'}-${v.speed_status}`,
          heading:hdg,
          speed_ms:v.speed_ms,
          speed_status:v.speed_status,
          passengers:v.passengers,
          label:v.passengers>0?String(v.passengers):'',
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
      socket.onopen=()=>ALL_LINE_IDS.forEach(id=>
        socket.send(JSON.stringify({type:'subscribe',payload:{line_id:id}}))
      )
      socket.onmessage=(e)=>{
        const msg=JSON.parse(e.data)
        if(msg.type!=='vehicle_update') return
        const{lineId,vehicles}=msg.payload
        const now=performance.now()
        ;(vehicles??[]).forEach((v:any)=>{
          const key=v.wagon_id as string
          const prev=stateRef.current.get(key)
          stateRef.current.set(key,{
            wagon_id:key, line_id:lineId,
            fromLng:prev?.toLng??v.longitude, fromLat:prev?.toLat??v.latitude,
            toLng:v.longitude, toLat:v.latitude,
            fromHdg:prev?.toHdg??(v.heading??0), toHdg:v.heading??0,
            speed_ms:v.speed_ms??0, speed_status:v.speed_status??'normal',
            passengers:v.passengers??0, startedAt:now,
          })
        })
      }
      socket.onclose=()=>setTimeout(connect,3000)
    }
    connect()
    return()=>{cancelAnimationFrame(rafId.current); ws.current?.close()}
  },[ready,renderLoop])

  return <div ref={containerRef} style={{width:'100vw',height:'100vh'}}/>
}
