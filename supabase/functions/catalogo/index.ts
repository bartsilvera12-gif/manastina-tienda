// =============================================================================
// Edge Function: catalogo
// =============================================================================
// Le da al sitio el precio y el stock reales del ERP.
//
// La tienda es estática: las fotos, descripciones y colores siguen viniendo de
// datos-manastina.js. Lo que esta función aporta es lo único que cambia solo —
// cuánto sale y cuánto queda — para que la web no ofrezca algo que ya se vendió
// por el mostrador.
//
// Solo devuelve código, precio y stock. Nada de costos, proveedores ni ningún
// otro dato interno del ERP.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const env = (k: string, def = "") => (Deno.env.get(k) ?? def).trim();

const SITIO_URL = env("SITIO_URL", "https://manastina.com").replace(/\/+$/, "");
const SCHEMA = env("SUPABASE_SCHEMA", "manastina");

const ORIGENES_OK = new Set([
  SITIO_URL,
  SITIO_URL.replace("https://", "https://www."),
  "http://localhost:4700",
  "http://127.0.0.1:4700",
  "http://127.0.0.1:4703",
]);

function cabeceras(origen: string | null) {
  const permitido = origen && ORIGENES_OK.has(origen) ? origen : SITIO_URL;
  return {
    "Access-Control-Allow-Origin": permitido,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    Vary: "Origin",
    // Medio minuto de caché: suficiente para no golpear la base en cada visita,
    // y poco como para que un agotado se refleje enseguida.
    "Cache-Control": "public, max-age=30",
  };
}

Deno.serve(async (req) => {
  const origen = req.headers.get("Origin");

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cabeceras(origen) });
  }

  try {
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { db: { schema: SCHEMA } },
    );

    const { data, error } = await sb
      .from("v_web_catalogo")
      .select("codigo_web, precio, stock, activo");

    if (error) throw error;

    const productos = (data ?? [])
      .filter((p) => p?.codigo_web)
      .map((p) => ({
        id: String(p.codigo_web),
        precio: Number(p.precio ?? 0),
        stock: p.activo === false ? 0 : Math.max(0, Number(p.stock ?? 0)),
      }));

    return new Response(
      JSON.stringify({ productos, actualizado: new Date().toISOString() }),
      { headers: { ...cabeceras(origen), "Content-Type": "application/json" } },
    );
  } catch (e) {
    console.error("[catalogo]", e);
    // Que falle el stock no puede tumbar la tienda: se devuelve vacío y el
    // sitio sigue con los valores del archivo estático.
    return new Response(
      JSON.stringify({ productos: [], error: "no disponible" }),
      { status: 200, headers: { ...cabeceras(origen), "Content-Type": "application/json" } },
    );
  }
});
