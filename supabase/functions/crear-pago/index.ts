// =============================================================================
// Edge Function: crear-pago
// =============================================================================
// La llama el navegador desde manastina.com cuando el cliente aprieta
// "Pagar con PagoPar". Recibe el carrito y los datos del comprador, y devuelve
// el link de pago.
//
// Regla de oro: NO se confía en ningún monto que mande el navegador. Los
// precios se releen del catálogo publicado y el total se recalcula acá.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import {
  hashDesdeIniciar,
  iniciarTransaccion,
  limpiarClave,
  linkCheckout,
  respuestaOk,
  tokenIniciar,
  validarComprador,
  validarItem,
  validarSuma,
} from "../_shared/pagopar.ts";
import { ciudadPorClave, esZonaACoordinar } from "../_shared/ciudades.ts";

// -----------------------------------------------------------------------------
// Configuración (viene de los secretos de Supabase)
// -----------------------------------------------------------------------------
const env = (k: string, def = "") =>
  (Deno.env.get("MANASTINA_" + k) ?? Deno.env.get(k) ?? def).trim();

const PAGOPAR_PUBLIC_KEY = limpiarClave(env("PAGOPAR_PUBLIC_KEY"));
const PAGOPAR_PRIVATE_KEY = limpiarClave(env("PAGOPAR_PRIVATE_KEY"));
const SITIO_URL = env("SITIO_URL", "https://manastina.com").replace(/\/+$/, "");
const SCHEMA = env("SUPABASE_SCHEMA", "manastina");
const EMPRESA_ID = env("MANASTINA_EMPRESA_ID");

const FORMA_PAGO = Number(env("PAGOPAR_FORMA_PAGO", "9")) || 9;
const ITEM_CATEGORIA = env("PAGOPAR_ITEM_CATEGORIA", "909");
const ITEM_CIUDAD = env("PAGOPAR_ITEM_CIUDAD", "5");
const DIAS_VENCIMIENTO = Number(env("PAGOPAR_DIAS_VENCIMIENTO", "3")) || 3;
const RETURN_URL = env("PAGOPAR_RETURN_URL");
const WEBHOOK_URL = env("PAGOPAR_WEBHOOK_URL");

const VENDEDOR_TELEFONO = env("PAGOPAR_VENDEDOR_TELEFONO");
const VENDEDOR_DIRECCION = env("PAGOPAR_VENDEDOR_DIRECCION");
const VENDEDOR_REFERENCIA = env("PAGOPAR_VENDEDOR_DIRECCION_REFERENCIA");
const VENDEDOR_COORDENADAS = env("PAGOPAR_VENDEDOR_DIRECCION_COORDENADAS");

/** { "clave_ciudad": monto en guaraníes }. Ver pagopar/config.env. */
const ENVIO_TARIFAS: Record<string, number> = (() => {
  const raw = env("ENVIO_TARIFAS_JSON");
  if (!raw) return {};
  try {
    const obj = JSON.parse(raw);
    const salida: Record<string, number> = {};
    for (const [k, v] of Object.entries(obj)) {
      const n = Math.round(Number(v));
      if (Number.isFinite(n) && n >= 0) salida[String(k).trim()] = n;
    }
    return salida;
  } catch {
    console.error("[crear-pago] ENVIO_TARIFAS_JSON no es JSON válido; se ignora");
    return {};
  }
})();

/** Envío gratis a partir de este monto de compra. 0 = nunca. */
const ENVIO_GRATIS_DESDE = Number(env("ENVIO_GRATIS_DESDE", "0")) || 0;

// Orígenes que pueden llamar a esta función.
const ORIGENES_OK = new Set([
  SITIO_URL,
  SITIO_URL.replace("https://", "https://www."),
  "http://localhost:4700",
  "http://127.0.0.1:4700",
]);

function cabecerasCors(origen: string | null) {
  const permitido = origen && ORIGENES_OK.has(origen) ? origen : SITIO_URL;
  return {
    "Access-Control-Allow-Origin": permitido,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

function json(cuerpo: unknown, status: number, origen: string | null) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...cabecerasCors(origen), "Content-Type": "application/json" },
  });
}

// -----------------------------------------------------------------------------
// Catálogo
// -----------------------------------------------------------------------------
// La fuente de verdad es el ERP: manastina.productos, vía v_web_catalogo.
// Precio y stock salen de ahí, nunca del navegador.
//
// Si el ERP todavía no tiene los productos cargados (o la vista no existe),
// se cae al catalogo.json publicado, para que la tienda no deje de vender.
// -----------------------------------------------------------------------------
type ProductoCatalogo = {
  id: string;
  nombre: string;
  precio: number;
  stock: number;
  producto_id?: string | null;
  activo?: boolean;
};

/** Cliente con la service_role, apuntando al schema del ERP. */
function erp() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { db: { schema: SCHEMA } },
  );
}
type Erp = ReturnType<typeof erp>;

/** El stock se relee seguido: es lo que evita vender algo que ya no está. */
const CACHE_MS = 30 * 1000;

let catalogoCache: { datos: Map<string, ProductoCatalogo>; vence: number } | null = null;

async function catalogoDesdeErp(
  sb: Erp,
): Promise<Map<string, ProductoCatalogo> | null> {
  const { data, error } = await sb
    .from("v_web_catalogo")
    .select("codigo_web, producto_id, nombre, precio, stock, activo");

  if (error) {
    console.warn("[crear-pago] no se pudo leer el catálogo del ERP:", error.message);
    return null;
  }
  if (!data || data.length === 0) return null;

  const mapa = new Map<string, ProductoCatalogo>();
  for (const p of data) {
    if (!p?.codigo_web) continue;
    mapa.set(String(p.codigo_web), {
      id: String(p.codigo_web),
      nombre: String(p.nombre ?? ""),
      precio: Number(p.precio ?? 0),
      stock: Number(p.stock ?? 0),
      producto_id: p.producto_id ? String(p.producto_id) : null,
      activo: p.activo !== false,
    });
  }
  return mapa;
}

async function catalogoDesdeSitio(): Promise<Map<string, ProductoCatalogo>> {
  const res = await fetch(`${SITIO_URL}/catalogo.json`, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`No se pudo leer el catálogo (HTTP ${res.status})`);
  const lista = (await res.json()) as ProductoCatalogo[];
  if (!Array.isArray(lista) || lista.length === 0) {
    throw new Error("El catálogo publicado está vacío");
  }
  const mapa = new Map<string, ProductoCatalogo>();
  for (const p of lista) {
    if (p && p.id) mapa.set(String(p.id), { ...p, activo: true });
  }
  return mapa;
}

async function traerCatalogo(
  sb: Erp,
): Promise<{ datos: Map<string, ProductoCatalogo>; fuente: "erp" | "sitio" }> {
  const ahora = Date.now();
  if (catalogoCache && catalogoCache.vence > ahora) {
    return { datos: catalogoCache.datos, fuente: "erp" };
  }

  const delErp = await catalogoDesdeErp(sb);
  if (delErp) {
    catalogoCache = { datos: delErp, vence: ahora + CACHE_MS };
    return { datos: delErp, fuente: "erp" };
  }

  console.warn("[crear-pago] ERP sin catálogo; se usa catalogo.json del sitio");
  return { datos: await catalogoDesdeSitio(), fuente: "sitio" };
}

// -----------------------------------------------------------------------------
// Validaciones de entrada
// -----------------------------------------------------------------------------
const soloDigitos = (s: unknown) => String(s ?? "").replace(/\D/g, "");
const texto = (s: unknown, max = 200) => String(s ?? "").trim().slice(0, max);

function emailValido(s: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(s);
}

/**
 * Resuelve el envío del pedido.
 *
 *   cobrado   -> lo que se le suma al pago online (entra en monto_total).
 *   estimado  -> la tarifa de esa ciudad, se cobre ahora o al entregar.
 *                null cuando no hay tarifa publicada y hay que acordarla.
 *   aparte    -> true si queda plata por cobrar al momento de entregar.
 *
 * Reglas:
 *   - Retiro en el local: no hay envío.
 *   - Ciudad fuera de la lista: siempre aparte, porque no sabemos cuánto sale.
 *   - Si el cliente eligió pagarlo al recibir, no entra en el cobro online.
 */
function resolverEnvio(
  modalidad: string,
  ciudadClave: string,
  cuandoPaga: string,
  subtotal: number,
): { cobrado: number; estimado: number | null; aparte: boolean } {
  if (modalidad === "retiro") return { cobrado: 0, estimado: 0, aparte: false };

  // Fuera de la zona de reparto: el costo se acuerda y se cobra al entregar.
  if (esZonaACoordinar(ciudadClave)) return { cobrado: 0, estimado: null, aparte: true };

  const tarifa = ENVIO_TARIFAS[String(ciudadClave).trim()];
  if (!Number.isFinite(tarifa)) {
    // Ciudad conocida pero sin tarifa cargada: no inventamos un precio.
    console.warn("[crear-pago] sin tarifa para la ciudad", ciudadClave);
    return { cobrado: 0, estimado: null, aparte: true };
  }

  if (ENVIO_GRATIS_DESDE > 0 && subtotal >= ENVIO_GRATIS_DESDE) {
    return { cobrado: 0, estimado: 0, aparte: false };
  }

  // El cliente eligió abonárselo al repartidor.
  if (cuandoPaga === "recibir") return { cobrado: 0, estimado: tarifa, aparte: true };

  return { cobrado: tarifa, estimado: tarifa, aparte: false };
}

/** `id_pedido_comercio` tiene que ser entero; es el mismo valor que firma el token. */
function nuevoIdPedidoComercio(): number {
  return Math.floor(100_000_000 + Math.random() * 900_000_000);
}

// -----------------------------------------------------------------------------
Deno.serve(async (req) => {
  const origen = req.headers.get("Origin");

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cabecerasCors(origen) });
  }
  if (req.method !== "POST") {
    return json({ error: "Método no permitido" }, 405, origen);
  }
  if (!PAGOPAR_PUBLIC_KEY || !PAGOPAR_PRIVATE_KEY) {
    console.error("[crear-pago] faltan las claves de PagoPar en los secretos");
    return json({ error: "El cobro online no está configurado todavía." }, 503, origen);
  }

  try {
    const cuerpo = await req.json();

    // --- Comprador ---------------------------------------------------------
    const c = cuerpo?.cliente ?? {};
    const nombre = texto(c.nombre);
    const email = texto(c.email).toLowerCase();
    const telefono = soloDigitos(c.telefono).slice(0, 20);
    const documento = soloDigitos(c.documento).slice(0, 20);
    const ciudadClave = texto(c.ciudad, 40);
    const envioCuandoPaga = c.envio_pago === "recibir" ? "recibir" : "ahora";
    const direccion = texto(c.direccion);
    const referencia = texto(c.referencia);
    const modalidad = c.modalidad === "retiro" ? "retiro" : "envio";
    const observaciones = texto(c.observaciones, 500);

    const faltantes: string[] = [];
    if (nombre.length < 3) faltantes.push("nombre");
    if (!emailValido(email)) faltantes.push("email");
    if (telefono.length < 6) faltantes.push("teléfono");
    if (documento.length < 5) faltantes.push("cédula");
    const ciudad = ciudadPorClave(ciudadClave);
    if (!ciudad) faltantes.push("ciudad");
    if (modalidad === "envio" && direccion.length < 5) faltantes.push("dirección");
    if (faltantes.length) {
      return json({ error: `Faltan datos: ${faltantes.join(", ")}.` }, 400, origen);
    }

    // --- Carrito, con precios releídos del catálogo -------------------------
    const entrada = Array.isArray(cuerpo?.items) ? cuerpo.items : [];
    if (entrada.length === 0) return json({ error: "El carrito está vacío." }, 400, origen);
    if (entrada.length > 50) return json({ error: "Demasiados ítems." }, 400, origen);

    const sb = erp();

    const { datos: catalogo, fuente } = await traerCatalogo(sb);

    const lineas: {
      producto_codigo: string;
      producto_id: string | null;
      nombre: string;
      color: string;
      cantidad: number;
      precio_unitario: number;
      total_linea: number;
    }[] = [];

    // Un mismo producto puede venir en varias líneas (distinto color): el stock
    // se controla sobre el total pedido, no línea por línea.
    const pedidoPorProducto = new Map<string, number>();
    for (const it of entrada) {
      const codigo = texto(it?.id, 40);
      const cant = Math.floor(Number(it?.cantidad) || 0);
      pedidoPorProducto.set(codigo, (pedidoPorProducto.get(codigo) ?? 0) + cant);
    }

    for (const it of entrada) {
      const codigo = texto(it?.id, 40);
      const producto = catalogo.get(codigo);
      if (!producto || producto.activo === false) {
        return json({ error: `El producto "${codigo}" ya no está disponible.` }, 409, origen);
      }
      const cantidad = Math.floor(Number(it?.cantidad) || 0);
      if (cantidad < 1 || cantidad > 99) {
        return json({ error: `Cantidad inválida para ${producto.nombre}.` }, 400, origen);
      }

      // Stock real del ERP. Se mira una sola vez por producto, sumando todas
      // las líneas que lo incluyan.
      const totalPedido = pedidoPorProducto.get(codigo) ?? cantidad;
      const disponible = Number(producto.stock ?? 0);
      if (disponible <= 0) {
        return json({ error: `${producto.nombre} está sin stock.` }, 409, origen);
      }
      if (totalPedido > disponible) {
        return json(
          {
            error: disponible === 1
              ? `Queda una sola unidad de ${producto.nombre}.`
              : `Quedan ${disponible} unidades de ${producto.nombre}.`,
            codigo,
            disponible,
          },
          409,
          origen,
        );
      }

      // El precio SIEMPRE sale del catálogo, nunca del navegador.
      const precio = Math.round(Number(producto.precio) || 0);
      if (precio <= 0) {
        return json({ error: `El producto ${producto.nombre} no tiene precio.` }, 409, origen);
      }

      lineas.push({
        producto_codigo: codigo,
        producto_id: producto.producto_id ?? null,
        nombre: producto.nombre,
        color: texto(it?.color, 60),
        cantidad,
        precio_unitario: precio,
        total_linea: precio * cantidad,
      });
    }

    const subtotal = lineas.reduce((a, l) => a + l.total_linea, 0);
    const env2 = resolverEnvio(modalidad, ciudadClave, envioCuandoPaga, subtotal);
    const envio = env2.cobrado;
    const envioAparte = env2.aparte;
    const total = subtotal + envio;
    if (total <= 0) return json({ error: "Total inválido." }, 400, origen);

    // --- Guardar el pedido antes de llamar a PagoPar ------------------------
    const idPedidoComercio = nuevoIdPedidoComercio();

    const { data: pedido, error: errPedido } = await sb
      .from("web_pedidos")
      .insert({
        id_pedido_comercio: idPedidoComercio,
        empresa_id: EMPRESA_ID || null,
        cliente_nombre: nombre,
        cliente_email: email,
        cliente_telefono: telefono,
        cliente_documento: documento,
        ciudad_codigo: ciudadClave,
        ciudad_nombre: ciudad!.nombre,
        ciudad_hub_pagopar: ciudad!.hub,
        envio_estimado: env2.estimado,
        direccion,
        direccion_referencia: referencia,
        modalidad,
        observaciones,
        subtotal,
        envio,
        envio_aparte: envioAparte,
        total,
        estado_pago: "pendiente",
      })
      .select("id")
      .single();

    if (errPedido) throw errPedido;

    const { error: errItems } = await sb
      .from("web_pedido_items")
      .insert(lineas.map((l) => ({ pedido_id: pedido.id, ...l })));
    if (errItems) throw errItems;

    // --- Payload de PagoPar -------------------------------------------------
    const comprador = {
      ruc: "",
      email,
      ciudad: ciudad!.hub,
      nombre,
      telefono,
      direccion,
      documento,
      coordenadas: "",
      razon_social: "",
      tipo_documento: "CI",
      direccion_referencia: referencia,
    };
    validarComprador(comprador);

    // Una sola línea agregada: PagoPar solo necesita cobrar el total.
    // El detalle real queda en web_pedido_items.
    const resumen = lineas.length === 1
      ? lineas[0].nombre
      : `${lineas.length} artículos`;

    const item = {
      ciudad: ITEM_CIUDAD,
      nombre: `Pedido MANASTINA #${idPedidoComercio}`,
      cantidad: 1,
      categoria: ITEM_CATEGORIA,
      public_key: PAGOPAR_PUBLIC_KEY,
      url_imagen: `${SITIO_URL}/assets/logo-isotipo-borgona.png`,
      descripcion: `${resumen}${envio > 0 ? " + envío" : ""}`.slice(0, 200),
      id_producto: idPedidoComercio,
      precio_total: total,
      vendedor_telefono: VENDEDOR_TELEFONO,
      vendedor_direccion: VENDEDOR_DIRECCION,
      vendedor_direccion_referencia: VENDEDOR_REFERENCIA,
      vendedor_direccion_coordenadas: VENDEDOR_COORDENADAS,
    };
    validarItem(item);
    validarSuma([item], total);

    const vence = new Date(Date.now() + DIAS_VENCIMIENTO * 86_400_000);

    const payload: Record<string, unknown> = {
      token: await tokenIniciar(PAGOPAR_PRIVATE_KEY, idPedidoComercio, total),
      comprador,
      public_key: PAGOPAR_PUBLIC_KEY,
      monto_total: total,
      tipo_pedido: "VENTA-COMERCIO",
      compras_items: [item],
      fecha_maxima_pago: vence.toISOString().slice(0, 19).replace("T", " "),
      id_pedido_comercio: idPedidoComercio,
      descripcion_resumen: `MANASTINA #${idPedidoComercio}`,
      forma_pago: FORMA_PAGO,
    };
    if (RETURN_URL) payload.url_respuesta = RETURN_URL;
    if (WEBHOOK_URL) payload.url_notificacion = WEBHOOK_URL;

    // --- Llamada a PagoPar --------------------------------------------------
    const pp = await iniciarTransaccion(payload);

    if (!respuestaOk(pp.respuesta)) {
      console.error("[crear-pago] PagoPar rechazó la transacción", JSON.stringify(pp).slice(0, 800));
      await sb.from("web_pedidos")
        .update({ estado_pago: "rechazado", pagopar_respuesta: pp })
        .eq("id", pedido.id);
      return json(
        { error: "PagoPar rechazó el pedido.", detalle: pp?.mensaje ?? null },
        502,
        origen,
      );
    }

    const hash = hashDesdeIniciar(pp);
    if (!hash) {
      console.error("[crear-pago] PagoPar no devolvió hash", JSON.stringify(pp).slice(0, 800));
      return json({ error: "PagoPar no devolvió el link de pago." }, 502, origen);
    }

    const link = linkCheckout(hash);

    await sb.from("web_pedidos")
      .update({ pagopar_hash: hash, pagopar_link: link, pagopar_respuesta: pp })
      .eq("id", pedido.id);

    console.info("[crear-pago] pedido creado", {
      pedido_id: pedido.id,
      id_pedido_comercio: idPedidoComercio,
      total,
      hash_prefijo: hash.slice(0, 8),
      catalogo: fuente,
    });

    return json(
      {
        link,
        pedido_id: pedido.id,
        numero: idPedidoComercio,
        subtotal,
        envio,
        envio_estimado: env2.estimado,
        total,
        // true = el envío no va incluido en este cobro; lo abona al recibirlo
        envio_aparte: envioAparte,
      },
      200,
      origen,
    );
  } catch (e) {
    console.error("[crear-pago]", e);
    const msg = e instanceof Error ? e.message : "Error inesperado";
    return json({ error: "No se pudo generar el pago.", detalle: msg }, 500, origen);
  }
});
