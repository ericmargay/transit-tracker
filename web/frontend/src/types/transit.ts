export type TransitSystem = 'metro' | 'metrobus'
export type CrowdingLevel = 'empty' | 'light' | 'moderate' | 'packed'

export interface TransitLine {
  id: string
  shortName: string
  displayName: string
  system: TransitSystem
  colorHex: string
  terminalA: string
  terminalB: string
}

export interface VehiclePosition {
  id: string
  lineId: string
  latitude: number
  longitude: number
  heading: number | null
  speedMs: number | null
  crowding: CrowdingLevel | null
  reportCount: number
  updatedAt: string
  isPrediction?: boolean
  confidence?: number
}

export interface WSMessage {
  type: 'vehicle_update' | 'prediction_update' | 'error'
  payload: Record<string, unknown>
}
