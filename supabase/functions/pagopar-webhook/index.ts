// =============================================================================
// Edge Function: pagopar-webhook
// =============================================================================
// La llama PagoPar (servidor a servidor) cuando cambia el estado de un cobro.
// El navegador nunca la toca.
//
// Se despliega con --no-verify-jwt: PagoPar no manda la anon key de Supabase.
// La autenticación real es el token SHA1 que viene en el cuerpo, y se valida
// contra la clave privada. Sin ese token, no se toca nada.
//
// PagoPar espera como respuesta el mismo `resultado` que envió, en un array.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import {
  estadoDesdePagopar,
  limpiarClave,
  primerResultado,
  tokenWebhookValido,
} from "../_shared/pagopar.ts";

// Prefijo MANASTINA_ para no chocar con las variables de otros clientes en el
// .env compartido del servidor. Si no está prefijada, se usa el nombre pelado.
const env = (k: string, def = "") =>
  (Deno.env.get("MANASTINA_" + k) ?? Deno.env.get(k) ?? def).trim();

const PAGOPAR_PRIVATE_KEY = limpiarClave(env("PAGOPAR_PRIVATE_KEY"));
const SCHEMA = env("SUPABASE_SCHEMA", "manastina");

/** PagoPar manda JSON, pero algunos avisos llegan como formulario. */
async function leerCuerpo(req: Request): Promise<Record<string, unknown>> {
  const tipo = (req.headers.get("content-type") ?? "").toLowerCase();
  if (tipo.includes("application/json")) {
    try {
      return await req.json();
    } catch {
      return {};
    }
  }
  try {
    const form = await req.formData();
    const obj: Record<string, unknown> = {};
    for (const [k, v] of form.entries()) obj[k] = typeof v === "string" ? v : String(v);
    return obj;
  } catch {
    try {
      return JSON.parse(await req.text());
    } catch {
      return {};
    }
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, error: "método no permitido" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const cuerpo = await leerCuerpo(req);

    let resultado: unknown = cuerpo.resultado;
    if (typeof resultado === "string") {
      try {
        resultado = JSON.parse(resultado);
      } catch {
        resultado = null;
      }
    }
    const item = primerResultado(resultado) ?? cuerpo;

    const hash = String(
      item.hash_pedido ?? item.hash ?? item.data ?? cuerpo.hash_pedido ?? cuerpo.hash ?? "",
    ).trim();
    const tokenRecibido = String(item.token ?? cuerpo.token ?? "");

    if (!hash) {
      console.warn("[webhook] aviso sin hash_pedido", JSON.stringify(cuerpo).slice(0, 400));
      return new Response(JSON.stringify({ ok: false, error: "falta hash" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    // --- Autenticación: sha1(clave_privada + hash) --------------------------
    if (!(await tokenWebhookValido(PAGOPAR_PRIVATE_KEY, hash, tokenRecibido))) {
      console.warn("[webhook] token inválido", { hash: hash.slice(0, 8) + "..." });
      return new Response(JSON.stringify({ ok: false, error: "token inválido" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const estado = estadoDesdePagopar(item, cuerpo);

    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { db: { schema: SCHEMA } },
    );

    const cambios: Record<string, unknown> = {
      estado_pago: estado,
      pagopar_respuesta: cuerpo,
    };
    if (estado === "pagado") {
      cambios.pagado_at = new Date().toISOString();
      const forma = item.forma_pago ?? item.descripcion_forma_pago;
      if (forma != null) cambios.pagopar_forma_pago = String(forma);
    }

    const { data: actualizado, error } = await sb
      .from("web_pedidos")
      .update(cambios)
      .eq("pagopar_hash", hash)
      .select("id, id_pedido_comercio, estado_pago")
      .maybeSingle();

    if (error) throw error;

    if (!actualizado) {
      console.warn("[webhook] ningún pedido con ese hash", { hash: hash.slice(0, 8) + "..." });
    } else {
      console.info("[webhook] pedido actualizado", {
        pedido_id: actualizado.id,
        numero: actualizado.id_pedido_comercio,
        estado,
      });

      // Pago confirmado: descontar el stock en el ERP.
      // La función es idempotente, así que si PagoPar reintenta el aviso no
      // se descuenta dos veces. Si falla, NO se rompe la respuesta a PagoPar:
      // la plata ya se cobró y el pedido quedó marcado como pagado igual.
      if (estado === "pagado") {
        try {
          const { data: r, error: errStock } = await sb.rpc("web_confirmar_pedido", {
            p_pedido: actualizado.id,
          });
          if (errStock) {
            console.error("[webhook][stock] no se pudo descontar", errStock.message);
          } else if (r?.repetido) {
            console.info("[webhook][stock] ya estaba descontado", { pedido_id: actualizado.id });
          } else {
            console.info("[webhook][stock] descontado", r);
            if (r?.lineas_sin_producto > 0) {
              console.warn(
                "[webhook][stock] hay lineas sin producto en el ERP; revisar a mano",
                r.faltantes,
              );
            }
          }
        } catch (e) {
          console.error("[webhook][stock] excepción", e instanceof Error ? e.message : e);
        }
      }
    }

    // --- Respuesta: PagoPar espera de vuelta su propio `resultado` ----------
    const salida = resultado == null
      ? []
      : Array.isArray(resultado)
      ? resultado
      : [resultado];

    return new Response(JSON.stringify(salida), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("[webhook]", e);
    return new Response(
      JSON.stringify({ ok: false, error: e instanceof Error ? e.message : "error" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
