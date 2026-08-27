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
import { cors } from "../_shared/cors.ts";

const env = (k: string, def = "") =>
  (Deno.env.get("MANASTINA_" + k) ?? Deno.env.get(k) ?? def).trim();

const SITIO_URL = env("SITIO_URL", "https://manastina.com").replace(/\/+$/, "");
const SCHEMA = env("SUPABASE_SCHEMA", "manastina");

function cabeceras(origen: string | null) {
  return {
    ...cors(origen, SITIO_URL, "GET, OPTIONS"),
    // `private`: solo el navegador de cada visitante puede guardarla. Con
    // `public`, Cloudflare la cachearia y les serviria a todos el mismo stock
    // durante minutos, mostrando disponible algo ya agotado.
    "Cache-Control": "private, max-age=30",
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
  nuevo_web: boolean | null;
  destacado_web: boolean | null;
};

/** Una fila de v_web_categorias. */
type FilaCategoria = {
  clave: string;
  categoria_id: string;
  nombre: string | null;
  descripcion: string | null;
  imagen_web_url: string | null;
  imagen_path: string | null;
  productos: number | null;
  orden_web: number | null;
};

/**
 * La clave con la que la tienda agrupa el producto. Sale del código de la
 * categoría en el ERP, o de su nombre si no tiene código. Ya no hay una lista
 * fija: si crean una categoría nueva, sus productos caen ahí solos.
 */
function categoriaWeb(codigo: string | null, nombre: string | null): string {
  const c = String(codigo ?? "").trim().toLowerCase();
  if (c) return c;
  const n = String(nombre ?? "").trim().toLowerCase();
  return n ? n.replace(/\s+/g, "-") : "otros";
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
          "descripcion_web, imagen_web_url, imagen_path, categoria_codigo, categoria_nombre, " +
          "nuevo_web, destacado_web",
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
      nuevo: p.nuevo_web === true,
      destacado: p.destacado_web === true,
    }));

    // --- Categorías ---------------------------------------------------------
    // Se piden aparte porque son pocas y cambian poco. Si la vista todavía no
    // existe, se devuelve lista vacía y el sitio usa las suyas.
    let categorias: {
      id: string;
      nombre: string;
      descripcion: string;
      imagen: string;
      productos: number;
    }[] = [];

    const { data: cats, error: errCats } = await sb
      .from("v_web_categorias")
      .select("clave, categoria_id, nombre, descripcion, imagen_web_url, imagen_path, productos, orden_web");

    if (errCats) {
      console.warn("[catalogo] sin categorías del ERP:", errCats.message);
    } else if (cats?.length) {
      const filasCat = cats as unknown as FilaCategoria[];

      // Igual que con los productos: la foto se copia una vez al bucket público.
      const nuevasCat = await publicarFotosPendientes(
        sb,
        filasCat.map((c) => ({
          producto_id: c.categoria_id,
          imagen_path: c.imagen_path,
          imagen_web_url: c.imagen_web_url,
        })),
        "categorias_productos",
        "categorias",
      );

      categorias = filasCat.map((c) => ({
        id: String(c.clave),
        nombre: String(c.nombre ?? ""),
        descripcion: String(c.descripcion ?? "").trim(),
        imagen: nuevasCat.get(String(c.categoria_id)) ?? c.imagen_web_url ?? "",
        productos: Number(c.productos ?? 0),
      }));
    }

    return new Response(
      JSON.stringify({ productos, categorias, actualizado: new Date().toISOString() }),
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
