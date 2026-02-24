import { useState, useEffect, useRef, useCallback } from 'react'
import type { VehiclePosition } from '../types/transit'

const WS_URL = import.meta.env.VITE_WS_URL ?? 'ws://localhost:8001'

export function useLiveVehicles(subscribedLineIds: string[]) {
  const [vehicles, setVehicles] = useState<Record<string, VehiclePosition>>({})
  const ws = useRef<WebSocket | null>(null)
  const subscribedRef = useRef<Set<string>>(new Set())

  const connect = useCallback(() => {
    ws.current = new WebSocket(`${WS_URL}/vehicles/ws`)
    ws.current.onopen = () => {
      subscribedRef.current.forEach(lineId => {
        ws.current?.send(JSON.stringify({ type: 'subscribe', payload: { line_id: lineId } }))
      })
    }
    ws.current.onmessage = (event) => {
      const msg = JSON.parse(event.data)
      if (msg.type === 'vehicle_update') {
        const v = msg.payload as VehiclePosition
        setVehicles(prev => ({ ...prev, [v.lineId]: v }))
      }
    }
    ws.current.onclose = () => setTimeout(connect, 3000)
  }, [])

  useEffect(() => {
    const prev = subscribedRef.current
    const next = new Set(subscribedLineIds)
    next.forEach(id => {
      if (!prev.has(id) && ws.current?.readyState === WebSocket.OPEN)
        ws.current.send(JSON.stringify({ type: 'subscribe', payload: { line_id: id } }))
    })
    prev.forEach(id => {
      if (!next.has(id) && ws.current?.readyState === WebSocket.OPEN)
        ws.current.send(JSON.stringify({ type: 'unsubscribe', payload: { line_id: id } }))
    })
    subscribedRef.current = next
  }, [subscribedLineIds])

  useEffect(() => { connect(); return () => ws.current?.close() }, [connect])
  return Object.values(vehicles)
}
