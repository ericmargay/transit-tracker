const API = import.meta.env.VITE_API_URL ?? 'http://localhost:8001'

let sessionId: string = localStorage.getItem('transit_session_id') ?? ''
if (!sessionId) {
  sessionId = crypto.randomUUID()
  localStorage.setItem('transit_session_id', sessionId)
}
export { sessionId }

export async function submitVehicleReport(payload: {
  line_id: string
  latitude: number
  longitude: number
  heading: number | null
  speed_ms: number | null
  crowding?: string | null
}) {
  return fetch(`${API}/vehicles/report`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...payload, session_id: sessionId }),
  })
}
