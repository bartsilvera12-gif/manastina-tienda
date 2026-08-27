// =============================================================================
// Edge Function: catalogo
// =============================================================================
// Le da al sitio los productos publicados en el ERP.
//
// Manda el chip `visible_web` de manastina.productos: lo que esté marcado sale
// en la tienda, lo que no, queda solo en el inventario interno.
//
// De cada producto devuelve lo mínimo para armar la ficha: nombre, precio,
// stock, categoría, descripción y foto. Nada de costos, proveedores ni ningún
// otro dato interno.
//
// Los productos que además están en datos-manastina.js se enriquecen del lado
// del sitio con las fotos por ángulo y los colores. Los que no, salen con lo
// que tenga el ERP.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { publicarFotosPendientes } from "../_shared/fotos.ts";

const env = (k: string, def = "") => (Deno.env.get(k) ?? def).trim();

const SITIO_URL = env("SITIO_URL", "https://manastina.com").replace(/\/+$/, "");
const SCHEMA = env("SUPABASE_SCHEMA", "manastina");

const ORIGENES_OK = new Set([
  SITIO_URL,
  SITIO_URL.replace("https://", "https://www."),
  "http://localhost:4700",
  "http://127.0.0.1:4700",
  "http://127.0.0.1:4703",
  "http://127.0.0.1:4704",
  "http://127.0.0.1:4705",
]);

function cabeceras(origen: string | null) {
  const permitido = origen && ORIGENES_OK.has(origen) ? origen : SITIO_URL;
  return {
    "Access-Control-Allow-Origin": permitido,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    Vary: "Origin",
    // Medio minuto: no golpea la base en cada visita, y un agotado se refleja
    // enseguida.
    "Cache-Control": "public, max-age=30",
  };
}

/** Una fila de v_web_catalogo. El cliente no conoce el schema, así que se tipa acá. */
type FilaCatalogo = {
  codigo_web: string | null;
  producto_id: string;
  nombre: string | null;
  precio: number | null;
  stock: number | null;
  activo: boolean | null;
  descripcion_web: string | null;
  imagen_web_url: string | null;
  imagen_path: string | null;
  categoria_codigo: string | null;
  categoria_nombre: string | null;
};

/** Categoría del ERP -> categoría de la tienda. Si no coincide, va a la genérica. */
const CATEGORIAS_WEB = new Set(["carteras", "bandoleras", "accesorios", "sets"]);

function categoriaWeb(codigo: string | null, nombre: string | null): string {
  const c = String(codigo ?? "").trim().toLowerCase();
  if (CATEGORIAS_WEB.has(c)) return c;
  const n = String(nombre ?? "").trim().toLowerCase();
  for (const cat of CATEGORIAS_WEB) {
    if (n.includes(cat.slice(0, 6))) return cat;
  }
  return "accesorios";
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
      .select(
        "codigo_web, producto_id, nombre, precio, stock, activo, " +
          "descripcion_web, imagen_web_url, imagen_path, categoria_codigo, categoria_nombre",
      );

    if (error) throw error;

    const filas = ((data ?? []) as unknown as FilaCatalogo[]).filter((p) => p?.codigo_web);

    // Publica las fotos que todavía no tengan URL pública. Se hace una sola
    // vez por producto: la próxima visita ya las encuentra hechas.
    const nuevas = await publicarFotosPendientes(sb, filas);

    const productos = filas.map((p) => ({
      id: String(p.codigo_web),
      nombre: String(p.nombre ?? ""),
      precio: Number(p.precio ?? 0),
      stock: p.activo === false ? 0 : Math.max(0, Number(p.stock ?? 0)),
      categoria: categoriaWeb(p.categoria_codigo, p.categoria_nombre),
      descripcion: String(p.descripcion_web ?? "").trim(),
      imagen: nuevas.get(String(p.producto_id)) ?? p.imagen_web_url ?? "",
    }));

    return new Response(
      JSON.stringify({ productos, actualizado: new Date().toISOString() }),
      { headers: { ...cabeceras(origen), "Content-Type": "application/json" } },
    );
  } catch (e) {
    console.error("[catalogo]", e);
    // Que falle esto no puede tumbar la tienda: se devuelve vacío y el sitio
    // sigue con los productos del archivo estático.
    return new Response(
      JSON.stringify({ productos: [], error: "no disponible" }),
      { status: 200, headers: { ...cabeceras(origen), "Content-Type": "application/json" } },
    );
  }
});
