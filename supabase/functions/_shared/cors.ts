// =============================================================================
// Qué páginas pueden llamar a las funciones
// =============================================================================
// El navegador exige que la función diga explícitamente desde qué dirección
// acepta pedidos. Si no coincide, la llamada ni siquiera llega: el navegador
// la corta y muestra "Failed to fetch", sin más detalle.
//
// Por eso la lista es tolerante a las formas en que suele aparecer el mismo
// sitio: con y sin www, el dominio de prueba del hosting, y localhost mientras
// se desarrolla. Cualquier otra queda afuera y se anota en los registros, para
// poder verla en vez de andar adivinando.
// =============================================================================

/** Orígenes extra, separados por coma. Sirve para un dominio de prueba. */
function extras(): string[] {
  const raw = (Deno.env.get("MANASTINA_ORIGENES_EXTRA") ??
    Deno.env.get("ORIGENES_EXTRA") ?? "").trim();
  return raw ? raw.split(",").map((s) => s.trim()).filter(Boolean) : [];
}

function host(url: string): string {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
}

/**
 * @param origen  el `Origin` que mandó el navegador
 * @param sitio   la dirección pública del sitio (SITIO_URL)
 */
export function origenPermitido(origen: string | null, sitio: string): boolean {
  if (!origen) return false;

  const h = host(origen);
  if (!h) return false;

  // Desarrollo local, en cualquier puerto.
  if (h === "localhost" || h === "127.0.0.1") return true;

  const propio = host(sitio);
  if (propio) {
    // El dominio del sitio y cualquier subdominio suyo (www, tienda, etc.).
    if (h === propio || h.endsWith("." + propio)) return true;
    // manastina.com <-> www.manastina.com, cuando SITIO_URL trae el www.
    const sinWww = propio.replace(/^www\./, "");
    if (h === sinWww || h.endsWith("." + sinWww)) return true;
  }

  // Los dominios de prueba que da el hosting mientras el dominio real no apunta.
  if (h.endsWith(".hostingersite.com") || h.endsWith(".vercel.app")) return true;

  for (const e of extras()) {
    const he = host(e) || e.toLowerCase();
    if (h === he) return true;
  }

  return false;
}

/**
 * Cabeceras para la respuesta. Si el origen no está permitido se devuelve el
 * del sitio, que hace que el navegador corte la llamada — pero queda anotado
 * cuál fue, así se puede corregir.
 */
export function cors(
  origen: string | null,
  sitio: string,
  metodos = "POST, OPTIONS",
): Record<string, string> {
  const ok = origenPermitido(origen, sitio);
  if (!ok && origen) {
    console.warn("[cors] origen no permitido:", origen, "· sitio configurado:", sitio);
  }
  return {
    "Access-Control-Allow-Origin": ok ? (origen as string) : sitio,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": metodos,
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}
