-- =============================================================================
-- MANASTINA · Vista de pedidos web para el ERP
-- =============================================================================
-- Correr DESPUÉS de 01-tablas-web.sql, en el SQL Editor.
--
-- Deja todo lo que el ERP necesita en una sola consulta: quién compró, a dónde
-- va, qué lleva, si está pagado y si queda envío por cobrar. Sin joins.
--
--   select * from manastina.v_web_pedidos where estado_pago = 'pagado';
--
-- No toca ninguna tabla del ERP: es una vista sobre las dos tablas `web_`.
-- =============================================================================

create or replace view manastina.v_web_pedidos as
select
  p.id,
  p.id_pedido_comercio                              as numero_pedido,
  p.empresa_id,

  -- --- Estado ------------------------------------------------------------
  p.estado_pago,
  (p.estado_pago = 'pagado')                        as esta_pagado,
  p.pagado_at,
  p.created_at                                      as fecha_pedido,

  -- true = el envío NO se cobró online; se lo cobra el delivery al entregar.
  p.envio_aparte                                    as cobrar_envio_al_entregar,

  -- --- Cliente -----------------------------------------------------------
  p.cliente_nombre,
  p.cliente_telefono,
  p.cliente_email,
  p.cliente_documento,

  -- Teléfono en formato internacional, listo para WhatsApp.
  -- Convierte 0981123456 -> 595981123456 y deja tal cual lo que ya venga con 595.
  case
    when p.cliente_telefono ~ '^595'  then p.cliente_telefono
    when p.cliente_telefono ~ '^0'    then '595' || substring(p.cliente_telefono from 2)
    when length(p.cliente_telefono) = 9 then '595' || p.cliente_telefono
    else p.cliente_telefono
  end                                               as whatsapp_numero,

  -- Link directo para escribirle, con el mensaje ya cargado.
  -- El texto se arma solo con letras sin acento y el número de pedido, para no
  -- depender de cómo se codifiquen los nombres del cliente en la URL.
  'https://wa.me/' ||
    case
      when p.cliente_telefono ~ '^595'  then p.cliente_telefono
      when p.cliente_telefono ~ '^0'    then '595' || substring(p.cliente_telefono from 2)
      when length(p.cliente_telefono) = 9 then '595' || p.cliente_telefono
      else p.cliente_telefono
    end ||
    '?text=Hola,%20te%20escribimos%20de%20MANASTINA%20por%20tu%20pedido%20%23'
    || p.id_pedido_comercio                         as whatsapp_link,

  -- --- Entrega -----------------------------------------------------------
  p.modalidad,
  p.ciudad_codigo,
  p.ciudad_nombre,
  p.direccion,
  p.direccion_referencia,
  p.observaciones,

  -- --- Montos (guaraníes) ------------------------------------------------
  p.subtotal,
  p.envio                                           as envio_cobrado,
  p.total                                           as total_cobrado,

  -- --- Qué hay que preparar ----------------------------------------------
  coalesce(i.cantidad_articulos, 0)                 as cantidad_articulos,
  coalesce(i.resumen, '')                           as detalle,
  coalesce(i.items, '[]'::jsonb)                    as items,

  -- --- Enganche con el ERP ------------------------------------------------
  p.venta_id,
  p.cliente_id,
  p.pagopar_hash,
  p.pagopar_forma_pago                              as forma_pago

from manastina.web_pedidos p
left join lateral (
  select
    sum(d.cantidad)                                              as cantidad_articulos,
    string_agg(
      d.cantidad || ' x ' || d.nombre ||
      case when coalesce(d.color, '') <> '' then ' (' || d.color || ')' else '' end,
      ' · ' order by d.nombre
    )                                                            as resumen,
    jsonb_agg(
      jsonb_build_object(
        'codigo',          d.producto_codigo,
        'producto_id',     d.producto_id,
        'nombre',          d.nombre,
        'color',           d.color,
        'cantidad',        d.cantidad,
        'precio_unitario', d.precio_unitario,
        'total_linea',     d.total_linea
      ) order by d.nombre
    )                                                            as items
  from manastina.web_pedido_items d
  where d.pedido_id = p.id
) i on true;

comment on view manastina.v_web_pedidos is
  'Pedidos de la tienda web listos para el ERP: cliente, entrega, detalle, estado del cobro y link de WhatsApp. Filtrar por estado_pago = ''pagado'' para ver lo que hay que despachar.';


-- -----------------------------------------------------------------------------
-- Acceso
-- -----------------------------------------------------------------------------
-- La vista hereda el RLS de las tablas de abajo, asi que por defecto solo la
-- service_role la lee. Si el panel del ERP la consulta con un usuario logueado,
-- descomentá lo de abajo y ajustá la condicion a como el ERP identifica a la
-- empresa (por ejemplo contra manastina.usuario_modulos o el claim del JWT).
--
-- grant select on manastina.v_web_pedidos to authenticated;
--
-- create policy web_pedidos_lectura_erp on manastina.web_pedidos
--   for select to authenticated
--   using ( empresa_id = /* <-- empresa del usuario logueado */ );
--
-- create policy web_pedido_items_lectura_erp on manastina.web_pedido_items
--   for select to authenticated
--   using ( exists (
--     select 1 from manastina.web_pedidos p
--     where p.id = web_pedido_items.pedido_id
--       and p.empresa_id = /* <-- empresa del usuario logueado */
--   ) );
