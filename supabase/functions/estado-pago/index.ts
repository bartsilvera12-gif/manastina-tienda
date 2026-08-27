// =============================================================================
// Edge Function: estado-pago
// =============================================================================
// La usa la página de retorno (pago.html) para saber cómo terminó el cobro.
//
// Devuelve solo lo mínimo para armar el mensaje al cliente: estado, número de
// pedido y total. Nada de datos personales ni del resto de los pedidos.
//
// Si el webhook todavía no llegó (el cliente vuelve más rápido que el aviso),
// le pregunta directamente a PagoPar y actualiza el pedido.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import {
  consultarPedido,
  estadoDesdePagopar,
  limpiarClave,
  primerResultado,
} from "../_shared/pagopar.ts";
import { cors } from "../_shared/cors.ts";

const env = (k: string, def = "") =>
  (Deno.env.get("MANASTINA_" + k) ?? Deno.env.get(k) ?? def).trim();

const PAGOPAR_PUBLIC_KEY = limpiarClave(env("PAGOPAR_PUBLIC_KEY"));
const PAGOPAR_PRIVATE_KEY = limpiarClave(env("PAGOPAR_PRIVATE_KEY"));
const SITIO_URL = env("SITIO_URL", "https://manastina.com").replace(/\/+$/, "");
const SCHEMA = env("SUPABASE_SCHEMA", "manastina");

function cabecerasCors(origen: string | null) {
  return cors(origen, SITIO_URL, "GET, OPTIONS");
}

function json(cuerpo: unknown, status: number, origen: string | null) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...cabecerasCors(origen), "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const origen = req.headers.get("Origin");
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cabecerasCors(origen) });
  }

  try {
    const hash = new URL(req.url).searchParams.get("hash")?.trim() ?? "";
    if (!hash || hash.length < 10) {
      return json({ error: "Falta el identificador del pedido." }, 400, origen);
    }

    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { db: { schema: SCHEMA } },
    );

    const { data: pedido, error } = await sb
      .from("web_pedidos")
      .select(
        "id, id_pedido_comercio, estado_pago, total, modalidad, cliente_nombre, consultado_at",
      )
      .eq("pagopar_hash", hash)
      .maybeSingle();

    if (error) throw error;
    if (!pedido) return json({ error: "Pedido no encontrado." }, 404, origen);

    let estado = pedido.estado_pago as string;

    // Se le pregunta a PagoPar una vez por pedido, incluso si el aviso ya
    // llegó. Confirmar contra el origen es más sólido que fiarse solo del
    // aviso, y es además lo que PagoPar exige ver para habilitar producción.
    //
    // La marca `consultado_at` evita repetir la consulta si el cliente
    // recarga la página varias veces.
    const yaConsultado = pedido.consultado_at != null;
    const hayClaves = Boolean(PAGOPAR_PUBLIC_KEY && PAGOPAR_PRIVATE_KEY);

    if (!yaConsultado && hayClaves) {
      try {
        const pp = await consultarPedido(hash, {
          publica: PAGOPAR_PUBLIC_KEY,
          privada: PAGOPAR_PRIVATE_KEY,
        });
        const nuevo = estadoDesdePagopar(primerResultado(pp.resultado), pp);

        const cambios: Record<string, unknown> = {
          consultado_at: new Date().toISOString(),
        };

        // Solo se pisa el estado si PagoPar dice algo concreto. Si contesta
        // "pendiente" cuando el aviso ya lo dio por pagado, manda el aviso:
        // viene firmado y es posterior.
        if (nuevo !== "pendiente" && nuevo !== estado) {
          estado = nuevo;
          cambios.estado_pago = nuevo;
          cambios.pagopar_respuesta = pp;
          if (nuevo === "pagado") cambios.pagado_at = new Date().toISOString();
        }

        await sb.from("web_pedidos").update(cambios).eq("id", pedido.id);

        // Si acá nos enteramos del pago antes que el aviso, se cierra el
        // pedido igual. Es idempotente: cuando llegue el aviso no repite.
        if (estado === "pagado") {
          const { error: errVenta } = await sb.rpc("web_confirmar_pedido", {
            p_pedido: pedido.id,
          });
          if (errVenta) {
            console.error("[estado-pago] no se pudo cerrar el pedido:", errVenta.message);
          }
        }
      } catch (e) {
        // Si PagoPar no contesta, queda como estaba y el aviso lo resolverá.
        console.warn("[estado-pago] consulta a PagoPar falló:", e instanceof Error ? e.message : e);
      }
    }

    // Solo el primer nombre, para saludar sin exponer el nombre completo.
    const nombre = String(pedido.cliente_nombre ?? "").trim().split(/\s+/)[0] ?? "";

    return json(
      {
        estado,
        numero: pedido.id_pedido_comercio,
        total: pedido.total,
        modalidad: pedido.modalidad,
        nombre,
      },
      200,
      origen,
    );
  } catch (e) {
    console.error("[estado-pago]", e);
    return json({ error: "No se pudo consultar el pedido." }, 500, origen);
  }
});
