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

const env = (k: string, def = "") => (Deno.env.get(k) ?? def).trim();

const PAGOPAR_PUBLIC_KEY = limpiarClave(env("PAGOPAR_PUBLIC_KEY"));
const PAGOPAR_PRIVATE_KEY = limpiarClave(env("PAGOPAR_PRIVATE_KEY"));
const SITIO_URL = env("SITIO_URL", "https://manastina.com").replace(/\/+$/, "");
const SCHEMA = env("SUPABASE_SCHEMA", "manastina");

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
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    Vary: "Origin",
  };
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
      .select("id, id_pedido_comercio, estado_pago, total, modalidad, cliente_nombre")
      .eq("pagopar_hash", hash)
      .maybeSingle();

    if (error) throw error;
    if (!pedido) return json({ error: "Pedido no encontrado." }, 404, origen);

    let estado = pedido.estado_pago as string;

    // El cliente puede volver antes de que llegue el aviso de PagoPar.
    // En ese caso preguntamos directo y guardamos lo que responda.
    if (estado === "pendiente" && PAGOPAR_PUBLIC_KEY && PAGOPAR_PRIVATE_KEY) {
      try {
        const pp = await consultarPedido(hash, {
          publica: PAGOPAR_PUBLIC_KEY,
          privada: PAGOPAR_PRIVATE_KEY,
        });
        const nuevo = estadoDesdePagopar(primerResultado(pp.resultado), pp);
        if (nuevo !== "pendiente") {
          estado = nuevo;
          await sb
            .from("web_pedidos")
            .update({
              estado_pago: nuevo,
              pagopar_respuesta: pp,
              ...(nuevo === "pagado" ? { pagado_at: new Date().toISOString() } : {}),
            })
            .eq("id", pedido.id);
        }
      } catch (e) {
        // Si PagoPar no contesta, se queda en pendiente y el webhook lo resolverá.
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
