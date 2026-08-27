// =============================================================================
// Códigos de ciudad (hubs) de PagoPar
// =============================================================================
// PagoPar no acepta el nombre de la ciudad escrito a mano: espera uno de estos
// códigos. Esta misma lista alimenta el desplegable del checkout.
// =============================================================================

export const CIUDADES_PAGOPAR = [
  { codigo: "1", nombre: "Asunción", interior: false },
  { codigo: "2", nombre: "Ciudad del Este", interior: true },
  { codigo: "3", nombre: "San Lorenzo", interior: false },
  { codigo: "4", nombre: "Luque", interior: false },
  { codigo: "5", nombre: "Capiatá", interior: false },
  { codigo: "6", nombre: "Lambaré", interior: false },
  { codigo: "7", nombre: "Fernando de la Mora", interior: false },
  { codigo: "8", nombre: "Limpio", interior: false },
  { codigo: "9", nombre: "Ñemby", interior: false },
  { codigo: "10", nombre: "Encarnación", interior: true },
  { codigo: "11", nombre: "Pedro Juan Caballero", interior: true },
  { codigo: "12", nombre: "Coronel Oviedo", interior: true },
  { codigo: "13", nombre: "Villarrica", interior: true },
  { codigo: "14", nombre: "Caaguazú", interior: true },
  { codigo: "15", nombre: "Itauguá", interior: false },
] as const;

export function ciudadPorCodigo(codigo: string) {
  return CIUDADES_PAGOPAR.find((c) => c.codigo === String(codigo).trim()) ?? null;
}

/** true si la ciudad está fuera del Gran Asunción (tarifa de envío distinta). */
export function esInterior(codigo: string): boolean {
  return ciudadPorCodigo(codigo)?.interior ?? true;
}
