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
  marca_nombre: string | null;
};

/** Una fila de v_web_colecciones. */
type FilaColeccion = {
  coleccion_id: string;
  clave: string;
  nombre: string | null;
  frase: string | null;
  imagen_web_url: string | null;
  imagen_path: string | null;
  productos: string[] | null;
};

/** Una fila de v_web_producto_imagenes. */
type FilaGaleria = {
  imagen_id: string;
  producto_id: string;
  imagen_path: string | null;
  imagen_web_url: string | null;
  orden: number | null;
};

/** Una fila de v_web_marcas. */
type FilaMarca = {
  marca_id: string;
  clave: string;
  nombre: string | null;
  imagen_web_url: string | null;
  imagen_path: string | null;
  productos: number | null;
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
          "nuevo_web, destacado_web, marca_nombre",
      );

    if (error) throw error;

    const filas = ((data ?? []) as unknown as FilaCatalogo[]).filter((p) => p?.codigo_web);

    // Publica las fotos que todavía no tengan URL pública. Se hace una sola
    // vez por producto: la próxima visita ya las encuentra hechas.
    const nuevas = await publicarFotosPendientes(sb, filas);

    // --- Fotos adicionales ---------------------------------------------------
    // La portada de cada producto es `imagen`; acá vienen las que siguen, las
    // que el cliente pasa en la ficha. Si la vista todavía no existe, cada
    // producto queda con su portada sola.
    const galeria = new Map<string, string[]>();

    const { data: fotos, error: errFotos } = await sb
      .from("v_web_producto_imagenes")
      .select("imagen_id, producto_id, imagen_path, imagen_web_url, orden")
      .order("producto_id")
      .order("orden");

    if (errFotos) {
      console.warn("[catalogo] sin galería del ERP:", errFotos.message);
    } else if (fotos?.length) {
      const filasFoto = fotos as unknown as FilaGaleria[];

      const nuevasFoto = await publicarFotosPendientes(
        sb,
        filasFoto.map((f) => ({
          producto_id: f.imagen_id,
          imagen_path: f.imagen_path,
          imagen_web_url: f.imagen_web_url,
        })),
        "producto_imagenes",
        "galeria",
      );

      for (const f of filasFoto) {
        const url = nuevasFoto.get(String(f.imagen_id)) ?? f.imagen_web_url ?? "";
        if (!url) continue;
        const lista = galeria.get(String(f.producto_id)) ?? [];
        lista.push(url);
        galeria.set(String(f.producto_id), lista);
      }
    }

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
      marca: String(p.marca_nombre ?? "").trim(),
      imagenes: galeria.get(String(p.producto_id)) ?? [],
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

    // --- Marcas -------------------------------------------------------------
    // Las que estén activas en el ERP, con su logo. Si la vista todavía no
    // existe, el sitio usa las que trae escritas.
    let marcas: { id: string; nombre: string; logo: string; productos: number }[] = [];

    const { data: mks, error: errMks } = await sb
      .from("v_web_marcas")
      .select("marca_id, clave, nombre, imagen_web_url, imagen_path, productos");

    if (errMks) {
      console.warn("[catalogo] sin marcas del ERP:", errMks.message);
    } else if (mks?.length) {
      const filasMk = mks as unknown as FilaMarca[];

      const nuevasMk = await publicarFotosPendientes(
        sb,
        filasMk.map((m) => ({
          producto_id: m.marca_id,
          imagen_path: m.imagen_path,
          imagen_web_url: m.imagen_web_url,
        })),
        "marcas",
        "marcas",
      );

      marcas = filasMk.map((m) => ({
        id: String(m.clave),
        nombre: String(m.nombre ?? ""),
        logo: nuevasMk.get(String(m.marca_id)) ?? m.imagen_web_url ?? "",
        productos: Number(m.productos ?? 0),
      }));
    }

    // --- Colección de portada -----------------------------------------------
    // La que esté marcada como activa en el ERP. Si no hay ninguna, o la vista
    // todavía no existe, el sitio muestra la colección que trae escrita.
    let coleccion: {
      id: string;
      nombre: string;
      frase: string;
      imagen: string;
      productos: string[];
    } | null = null;

    const { data: cols, error: errCols } = await sb
      .from("v_web_colecciones")
      .select("coleccion_id, clave, nombre, frase, imagen_web_url, imagen_path, productos")
      .limit(1);

    if (errCols) {
      console.warn("[catalogo] sin colección del ERP:", errCols.message);
    } else if (cols?.length) {
      const c = (cols as unknown as FilaColeccion[])[0];

      const nuevasCol = await publicarFotosPendientes(
        sb,
        [{ producto_id: c.coleccion_id, imagen_path: c.imagen_path, imagen_web_url: c.imagen_web_url }],
        "colecciones_web",
        "colecciones",
      );

      coleccion = {
        id: String(c.clave),
        nombre: String(c.nombre ?? ""),
        frase: String(c.frase ?? "").trim(),
        imagen: nuevasCol.get(String(c.coleccion_id)) ?? c.imagen_web_url ?? "",
        productos: (c.productos ?? []).map((x) => String(x)),
      };
    }

    return new Response(
      JSON.stringify({ productos, categorias, marcas, coleccion, actualizado: new Date().toISOString() }),
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
