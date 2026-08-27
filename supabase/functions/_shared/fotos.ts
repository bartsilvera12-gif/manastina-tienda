// =============================================================================
// Publicación de fotos de producto
// =============================================================================
// El ERP guarda las fotos en un bucket PRIVADO (`productos-imagenes`) y las
// muestra con links firmados que vencen en una hora. Eso no sirve para una
// tienda: un <img> necesita una dirección que no caduque.
//
// Solución: la primera vez que un producto se publica, se copia su foto a un
// bucket público aparte y se guarda la URL definitiva en `imagen_web_url`.
//
//   - El bucket del inventario sigue privado. No se toca.
//   - Solo se copian las fotos de productos marcados `visible_web`.
//   - Se copia una sola vez por producto; después se reutiliza la URL.
//   - Las sirve el CDN de Supabase, no esta función.
// =============================================================================

const BUCKET_PRIVADO = "productos-imagenes";
export const BUCKET_PUBLICO = "tienda-web";

let bucketListo = false;

/** Crea el bucket público si no existe. Idempotente. */
async function asegurarBucket(sb: any): Promise<void> {
  if (bucketListo) return;
  try {
    const { data } = await sb.storage.getBucket(BUCKET_PUBLICO);
    if (data) {
      bucketListo = true;
      return;
    }
  } catch {
    // no existe: se crea abajo
  }
  const { error } = await sb.storage.createBucket(BUCKET_PUBLICO, {
    public: true,
    fileSizeLimit: 5 * 1024 * 1024,
    allowedMimeTypes: ["image/jpeg", "image/png", "image/webp"],
  });
  if (error && !/already exists|duplicate/i.test(error.message)) {
    throw new Error(`No se pudo crear el bucket público: ${error.message}`);
  }
  bucketListo = true;
}

/**
 * Copia la foto de un producto al bucket público y devuelve su URL.
 * Devuelve null si el producto no tiene foto o si algo falla: en ese caso la
 * tienda muestra el marcador de "foto pendiente" y sigue andando.
 */
export async function publicarFoto(
  sb: any,
  productoId: string,
  imagenPath: string,
): Promise<string | null> {
  if (!imagenPath) return null;

  try {
    await asegurarBucket(sb);

    // El path del ERP es `{empresa}/{producto}/principal.{ext}`.
    const ext = (imagenPath.split(".").pop() || "jpg").toLowerCase();
    const destino = `productos/${productoId}.${ext}`;

    const { data: archivo, error: errBajar } = await sb.storage
      .from(BUCKET_PRIVADO)
      .download(imagenPath);

    if (errBajar || !archivo) {
      console.warn("[fotos] no se pudo bajar", imagenPath, errBajar?.message);
      return null;
    }

    const tipo = ext === "png" ? "image/png" : ext === "webp" ? "image/webp" : "image/jpeg";

    const { error: errSubir } = await sb.storage
      .from(BUCKET_PUBLICO)
      .upload(destino, archivo, { contentType: tipo, upsert: true });

    if (errSubir) {
      console.warn("[fotos] no se pudo subir", destino, errSubir.message);
      return null;
    }

    const { data: pub } = sb.storage.from(BUCKET_PUBLICO).getPublicUrl(destino);
    return pub?.publicUrl ?? null;
  } catch (e) {
    console.warn("[fotos] excepción", e instanceof Error ? e.message : e);
    return null;
  }
}

/**
 * Se asegura de que cada producto de la lista tenga su foto publicada.
 * Trabaja sobre los que todavía no la tienen y guarda la URL para no repetir
 * el trabajo en la próxima visita.
 */
export async function publicarFotosPendientes(
  sb: any,
  productos: { producto_id: string; imagen_path?: string | null; imagen_web_url?: string | null }[],
): Promise<Map<string, string>> {
  const urls = new Map<string, string>();

  const pendientes = productos.filter((p) => !p.imagen_web_url && p.imagen_path);
  if (pendientes.length === 0) return urls;

  console.info("[fotos] publicando", pendientes.length, "foto(s)");

  for (const p of pendientes) {
    const url = await publicarFoto(sb, p.producto_id, p.imagen_path as string);
    if (!url) continue;

    urls.set(p.producto_id, url);
    const { error } = await sb
      .from("productos")
      .update({ imagen_web_url: url })
      .eq("id", p.producto_id);

    if (error) console.warn("[fotos] no se pudo guardar la URL", error.message);
  }

  return urls;
}
