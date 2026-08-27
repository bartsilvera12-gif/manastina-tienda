// =============================================================================
// PagoPar — lógica compartida por las Edge Functions
// =============================================================================
// Portado a Deno desde la implementación Node de tradexpar-digital-hub.
// Acá vive todo lo que toca la clave privada. Nunca llega al navegador.
// =============================================================================

export const API_BASE_PROD = "https://api.pagopar.com";
export const CHECKOUT_BASE_PROD = "https://www.pagopar.com/pagos";
export const PATH_INICIAR = "/api/comercios/2.0/iniciar-transaccion";
export const PATH_TRAER = "/api/pedidos/1.1/traer";

/** Limpia espacios, BOM y comillas que suelen venir al copiar la clave del panel. */
export function limpiarClave(raw: unknown): string {
  let s = String(raw ?? "").trim();
  if (s.charCodeAt(0) === 0xfeff) s = s.slice(1);
  const comillado =
    (s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"));
  if (comillado) s = s.slice(1, -1).trim();
  return s;
}

/** Vista parcial de una clave, para logs sin exponerla. */
export function enmascarar(clave: string): string {
  const s = String(clave || "");
  if (!s) return "(vacia)";
  if (s.length <= 8) return `*** (${s.length} chars)`;
  return `${s.slice(0, 4)}...${s.slice(-4)} (${s.length} chars)`;
}

export async function sha1Hex(texto: string): Promise<string> {
  const datos = new TextEncoder().encode(texto);
  const buf = await crypto.subtle.digest("SHA-1", datos);
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Equivalente al `strval(floatval($monto))` de PHP que espera PagoPar.
 * Tiene que dar exactamente el mismo string que el `monto_total` enviado,
 * o el token no coincide y PagoPar rechaza la transaccion.
 */
export function montoParaToken(monto: number | string): string {
  const n = Number(monto);
  if (!Number.isFinite(n) || n < 0) throw new Error(`Monto invalido: ${monto}`);
  const entero = Math.round(n);
  if (Math.abs(n - entero) < 1e-9) return String(entero);
  return n.toFixed(10).replace(/0+$/, "").replace(/\.$/, "") || "0";
}

/** Token de inicio: sha1(clave_privada + id_pedido_comercio + monto). */
export function tokenIniciar(
  clavePrivada: string,
  idPedidoComercio: number | string,
  montoTotal: number,
): Promise<string> {
  return sha1Hex(
    `${limpiarClave(clavePrivada)}${String(idPedidoComercio)}${montoParaToken(montoTotal)}`,
  );
}

/** Token generico para consultas: sha1(clave_privada + sufijo). */
export function tokenGenerico(clavePrivada: string, sufijo: string): Promise<string> {
  return sha1Hex(`${limpiarClave(clavePrivada)}${sufijo}`);
}

/**
 * Valida el aviso de pago: sha1(clave_privada + hash_pedido).
 * Comparacion de tiempo constante para no filtrar informacion por timing.
 */
export async function tokenWebhookValido(
  clavePrivada: string,
  hashPedido: string,
  tokenRecibido: string,
): Promise<boolean> {
  if (!clavePrivada || !hashPedido || !tokenRecibido) return false;
  const esperado = await sha1Hex(`${limpiarClave(clavePrivada)}${hashPedido}`);
  const a = new TextEncoder().encode(esperado);
  const b = new TextEncoder().encode(String(tokenRecibido));
  if (a.length !== b.length) return false;
  let dif = 0;
  for (let i = 0; i < a.length; i++) dif |= a[i] ^ b[i];
  return dif === 0;
}

/** PagoPar a veces manda `respuesta` como el string "true" en vez de booleano. */
export function respuestaOk(respuesta: unknown): boolean {
  if (respuesta === true) return true;
  const s = String(respuesta ?? "").trim().toLowerCase();
  return s === "true" || s === "t" || s === "1";
}

/** `resultado` puede venir como string JSON, array u objeto suelto. */
export function primerResultado(resultado: unknown): Record<string, unknown> | null {
  let r = resultado;
  if (typeof r === "string") {
    try {
      r = JSON.parse(r);
    } catch {
      return null;
    }
  }
  if (r == null) return null;
  if (Array.isArray(r)) {
    return r[0] && typeof r[0] === "object" ? (r[0] as Record<string, unknown>) : null;
  }
  if (typeof r === "object") return r as Record<string, unknown>;
  return null;
}

export type EstadoPago = "pagado" | "rechazado" | "pendiente";

/** Traduce la respuesta de PagoPar al estado que guardamos en web_pedidos. */
export function estadoDesdePagopar(
  item: Record<string, unknown> | null,
  cuerpo: Record<string, unknown>,
): EstadoPago {
  const f = item && typeof item === "object" ? item : {};
  const b = cuerpo && typeof cuerpo === "object" ? cuerpo : {};
  const pagado =
    f.pagado === true ||
    f.pagado === "t" ||
    f.pagado === "true" ||
    String(f.estado_transaccion) === "1" ||
    String(b.pagado) === "true";
  const cancelado =
    f.cancelado === true ||
    f.cancelado === "t" ||
    f.cancelado === "true" ||
    String(b.cancelado) === "true";
  if (pagado) return "pagado";
  if (cancelado) return "rechazado";
  return "pendiente";
}

/** Saca el hash del pedido de la respuesta de iniciar-transaccion. */
export function hashDesdeIniciar(cuerpo: Record<string, unknown>): string | null {
  const r = cuerpo?.resultado as unknown;
  if (Array.isArray(r) && r[0]) {
    const fila = r[0] as Record<string, unknown>;
    const h = fila.data ?? fila.hash_pedido ?? fila.hash;
    if (h) return String(h);
  }
  if (typeof r === "string" && r.length > 20) return r;
  return null;
}

export function linkCheckout(hashPedido: string, checkoutBase = CHECKOUT_BASE_PROD): string {
  const h = String(hashPedido || "").replace(/^\/+/, "");
  return `${checkoutBase.replace(/\/+$/, "")}/${h}`;
}

/** POST a iniciar-transaccion. Devuelve el JSON crudo de PagoPar. */
export async function iniciarTransaccion(
  payload: Record<string, unknown>,
  apiBase = API_BASE_PROD,
): Promise<Record<string, unknown>> {
  const url = `${apiBase.replace(/\/+$/, "")}${PATH_INICIAR}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const texto = await res.text();
  let data: Record<string, unknown>;
  try {
    data = JSON.parse(texto);
  } catch {
    throw new Error(`PagoPar no devolvio JSON (HTTP ${res.status}): ${texto.slice(0, 200)}`);
  }
  if (!res.ok) throw new Error(`PagoPar HTTP ${res.status}: ${texto.slice(0, 300)}`);
  return data;
}

/** Consulta el estado de un pedido por su hash. */
export async function consultarPedido(
  hashPedido: string,
  claves: { publica: string; privada: string },
  apiBase = API_BASE_PROD,
): Promise<Record<string, unknown>> {
  const h = String(hashPedido || "").trim();
  if (!h) throw new Error("hash_pedido requerido");
  const url = `${apiBase.replace(/\/+$/, "")}${PATH_TRAER}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({
      hash_pedido: h,
      token: await tokenGenerico(claves.privada, "CONSULTA"),
      token_publico: limpiarClave(claves.publica),
    }),
  });
  const texto = await res.text();
  if (!res.ok) throw new Error(`PagoPar traer HTTP ${res.status}: ${texto.slice(0, 300)}`);
  try {
    return JSON.parse(texto);
  } catch {
    throw new Error(`PagoPar traer: respuesta no JSON: ${texto.slice(0, 200)}`);
  }
}

// -----------------------------------------------------------------------------
// Forma exacta del payload. PagoPar valida la estructura completa: si sobra o
// falta una clave, rechaza el pedido. Estas constantes son el contrato.
// -----------------------------------------------------------------------------

export const CLAVES_COMPRADOR = [
  "ruc",
  "email",
  "ciudad",
  "nombre",
  "telefono",
  "direccion",
  "documento",
  "coordenadas",
  "razon_social",
  "tipo_documento",
  "direccion_referencia",
] as const;

export const CLAVES_ITEM = [
  "ciudad",
  "nombre",
  "cantidad",
  "categoria",
  "public_key",
  "url_imagen",
  "descripcion",
  "id_producto",
  "precio_total",
  "vendedor_telefono",
  "vendedor_direccion",
  "vendedor_direccion_referencia",
  "vendedor_direccion_coordenadas",
] as const;

export function validarComprador(comprador: Record<string, unknown>): void {
  const claves = Object.keys(comprador);
  if (claves.length !== CLAVES_COMPRADOR.length) {
    throw new Error(
      `[pagopar] comprador: se esperaban ${CLAVES_COMPRADOR.length} claves, hay ${claves.length}.`,
    );
  }
  for (const k of CLAVES_COMPRADOR) {
    if (!claves.includes(k)) throw new Error(`[pagopar] comprador: falta "${k}".`);
  }
}

export function validarItem(item: Record<string, unknown>): void {
  const claves = Object.keys(item);
  if (claves.length !== CLAVES_ITEM.length) {
    throw new Error(
      `[pagopar] compras_items: se esperaban ${CLAVES_ITEM.length} claves, hay ${claves.length}.`,
    );
  }
  for (const k of CLAVES_ITEM) {
    if (!claves.includes(k)) throw new Error(`[pagopar] compras_items: falta "${k}".`);
  }
  if (!Number.isInteger(item.cantidad)) {
    throw new Error("[pagopar] compras_items: cantidad debe ser entero.");
  }
  if (!Number.isInteger(item.precio_total)) {
    throw new Error("[pagopar] compras_items: precio_total debe ser entero (Gs).");
  }
}

/** La suma de las lineas tiene que dar exactamente el monto_total. */
export function validarSuma(items: Record<string, unknown>[], montoTotal: number): void {
  const suma = items.reduce((a, i) => a + Number(i.precio_total || 0), 0);
  if (suma !== montoTotal) {
    throw new Error(
      `[pagopar] la suma de compras_items (${suma}) no coincide con monto_total (${montoTotal}).`,
    );
  }
}
