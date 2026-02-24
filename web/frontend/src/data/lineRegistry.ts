import type { TransitLine } from '../types/transit'

export const METRO_LINES: TransitLine[] = [
  { id: 'metro-1',  shortName: 'L1',  displayName: 'Línea 1',  system: 'metro', colorHex: '#E91E8C', terminalA: 'Observatorio',   terminalB: 'Pantitlán' },
  { id: 'metro-2',  shortName: 'L2',  displayName: 'Línea 2',  system: 'metro', colorHex: '#1565C0', terminalA: 'Cuatro Caminos', terminalB: 'Tasqueña' },
  { id: 'metro-3',  shortName: 'L3',  displayName: 'Línea 3',  system: 'metro', colorHex: '#6A1B9A', terminalA: 'Indios Verdes',  terminalB: 'Universidad' },
  { id: 'metro-4',  shortName: 'L4',  displayName: 'Línea 4',  system: 'metro', colorHex: '#00838F', terminalA: 'Santa Anita',    terminalB: 'Martín Carrera' },
  { id: 'metro-5',  shortName: 'L5',  displayName: 'Línea 5',  system: 'metro', colorHex: '#FDD835', terminalA: 'Politécnico',    terminalB: 'Pantitlán' },
  { id: 'metro-6',  shortName: 'L6',  displayName: 'Línea 6',  system: 'metro', colorHex: '#E53935', terminalA: 'El Rosario',     terminalB: 'Martín Carrera' },
  { id: 'metro-7',  shortName: 'L7',  displayName: 'Línea 7',  system: 'metro', colorHex: '#FB8C00', terminalA: 'El Rosario',     terminalB: 'Barranca del Muerto' },
  { id: 'metro-8',  shortName: 'L8',  displayName: 'Línea 8',  system: 'metro', colorHex: '#558B2F', terminalA: 'Garibaldi',      terminalB: 'Constitución de 1917' },
  { id: 'metro-9',  shortName: 'L9',  displayName: 'Línea 9',  system: 'metro', colorHex: '#4E342E', terminalA: 'Tacubaya',       terminalB: 'Pantitlán' },
  { id: 'metro-a',  shortName: 'LA',  displayName: 'Línea A',  system: 'metro', colorHex: '#8D6E63', terminalA: 'La Paz',         terminalB: 'Pantitlán' },
  { id: 'metro-b',  shortName: 'LB',  displayName: 'Línea B',  system: 'metro', colorHex: '#90A4AE', terminalA: 'Buenavista',     terminalB: 'Ciudad Azteca' },
  { id: 'metro-12', shortName: 'L12', displayName: 'Línea 12', system: 'metro', colorHex: '#F9A825', terminalA: 'Mixcoac',        terminalB: 'Tláhuac' },
]

export const METROBUS_LINES: TransitLine[] = [
  { id: 'metrobus-1', shortName: 'MB1', displayName: 'Línea 1', system: 'metrobus', colorHex: '#E53935', terminalA: 'Indios Verdes', terminalB: 'El Caminero' },
  { id: 'metrobus-2', shortName: 'MB2', displayName: 'Línea 2', system: 'metrobus', colorHex: '#1565C0', terminalA: 'Tacubaya',      terminalB: 'Tepalcates' },
  { id: 'metrobus-3', shortName: 'MB3', displayName: 'Línea 3', system: 'metrobus', colorHex: '#2E7D32', terminalA: 'Tenayuca',      terminalB: 'Ciudad Universitaria' },
  { id: 'metrobus-4', shortName: 'MB4', displayName: 'Línea 4', system: 'metrobus', colorHex: '#6A1B9A', terminalA: 'Buenavista',    terminalB: 'Aeropuerto T1' },
  { id: 'metrobus-5', shortName: 'MB5', displayName: 'Línea 5', system: 'metrobus', colorHex: '#F57F17', terminalA: 'Politécnico',   terminalB: 'Río de los Remedios' },
  { id: 'metrobus-6', shortName: 'MB6', displayName: 'Línea 6', system: 'metrobus', colorHex: '#00838F', terminalA: 'El Rosario',    terminalB: 'Drail' },
  { id: 'metrobus-7', shortName: 'MB7', displayName: 'Línea 7', system: 'metrobus', colorHex: '#AD1457', terminalA: 'Campo Marte',   terminalB: 'Santa Fe' },
]

export const ALL_LINES = [...METRO_LINES, ...METROBUS_LINES]
export const lineById = (id: string) => ALL_LINES.find(l => l.id === id)
