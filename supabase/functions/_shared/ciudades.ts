// =============================================================================
// Ciudades de reparto de MANASTINA
// =============================================================================
// Dos cosas distintas que conviene no mezclar:
//
//   clave -> la ciudad real que elige el cliente. Es la que manda para calcular
//            el envío, y la que se guarda en el pedido para el ERP.
//
//   hub   -> el código que espera PagoPar. Su catálogo agrupa el país en pocas
//            zonas, así que varias ciudades caen en el mismo número. Sirve para
//            que la API acepte el pedido, no para tarifar.
//
// Las tarifas NO están acá: viven en ENVIO_TARIFAS_JSON (pagopar/config.env),
// para poder cambiarlas sin tocar código ni volver a desplegar.
// =============================================================================

export type Ciudad = { clave: string; nombre: string; hub: string };

export const CIUDADES: Ciudad[] = [
  { clave: "capiata", nombre: "Capiatá", hub: "5" },
  { clave: "san-lorenzo", nombre: "San Lorenzo", hub: "3" },
  { clave: "j-augusto-saldivar", nombre: "J. Augusto Saldívar", hub: "1" },
  { clave: "nemby", nombre: "Ñemby", hub: "9" },
  { clave: "ypane", nombre: "Ypané", hub: "1" },
  { clave: "itaugua", nombre: "Itauguá", hub: "15" },
  { clave: "fernando-de-la-mora", nombre: "Fernando de la Mora", hub: "7" },
  { clave: "aregua", nombre: "Areguá", hub: "1" },
  { clave: "villa-elisa", nombre: "Villa Elisa", hub: "1" },
  { clave: "luque", nombre: "Luque", hub: "4" },
  { clave: "san-antonio", nombre: "San Antonio", hub: "1" },
  { clave: "asuncion", nombre: "Asunción", hub: "1" },
  { clave: "lambare", nombre: "Lambaré", hub: "6" },
  { clave: "ita", nombre: "Itá", hub: "1" },
  { clave: "mariano-roque-alonso", nombre: "Mariano Roque Alonso", hub: "1" },
  { clave: "limpio", nombre: "Limpio", hub: "8" },

  // Fuera de la zona de reparto habitual: el costo se acuerda por WhatsApp y
  // se le cobra al entregar, porque no hay tarifa publicada.
  { clave: "otra", nombre: "Otra ciudad (coordinamos el envío)", hub: "1" },
];

export function ciudadPorClave(clave: string): Ciudad | null {
  const c = String(clave ?? "").trim();
  return CIUDADES.find((x) => x.clave === c) ?? null;
}

/** true si la ciudad no tiene tarifa publicada y hay que acordarla aparte. */
export function esZonaACoordinar(clave: string): boolean {
  return String(clave ?? "").trim() === "otra";
}
