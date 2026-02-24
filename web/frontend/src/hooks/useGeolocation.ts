import { useState, useRef, useCallback, useEffect } from 'react'

interface GeoState {
  latitude: number | null
  longitude: number | null
  heading: number | null
  speed: number | null
  error: string | null
  isActive: boolean
}

export function useGeolocation() {
  const [state, setState] = useState<GeoState>({
    latitude: null, longitude: null, heading: null,
    speed: null, error: null, isActive: false
  })
  const watchId = useRef<number | null>(null)

  const start = useCallback(() => {
    if (!navigator.geolocation) {
      setState(s => ({ ...s, error: 'Geolocation not supported' }))
      return
    }
    setState(s => ({ ...s, isActive: true, error: null }))
    watchId.current = navigator.geolocation.watchPosition(
      (pos) => setState({
        latitude: pos.coords.latitude, longitude: pos.coords.longitude,
        heading: pos.coords.heading, speed: pos.coords.speed,
        error: null, isActive: true,
      }),
      (err) => setState(s => ({ ...s, error: err.message, isActive: false })),
      { enableHighAccuracy: true, maximumAge: 5000, timeout: 10000 }
    )
  }, [])

  const stop = useCallback(() => {
    if (watchId.current !== null) {
      navigator.geolocation.clearWatch(watchId.current)
      watchId.current = null
    }
    setState(s => ({ ...s, isActive: false }))
  }, [])

  useEffect(() => () => stop(), [stop])
  return { ...state, start, stop }
}
