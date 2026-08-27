-- =============================================================================
-- MANASTINA · Pedidos web dentro del ERP
-- =============================================================================
-- Correr DESPUÉS de 06-visible-en-la-web.sql.
--
-- Deja dos cosas:
--
--   1. Seguimiento del envío en el pedido web: pendiente -> preparando ->
--      enviado -> entregado. Es lo que va a mostrar el módulo del ERP.
--
--   2. Que un pedido pagado se convierta en una VENTA del ERP, marcada con
--      origen 'web', para que aparezca en la pantalla de ventas de siempre.
--
-- -----------------------------------------------------------------------------
-- Lo importante de este script
-- -----------------------------------------------------------------------------
-- Cuando el ERP crea una venta, esa venta YA descuenta el stock y registra el
-- movimiento de inventario. Hasta ahora `web_confirmar_pedido` descontaba por
-- su cuenta, así que hacer las dos cosas habría descontado dos veces.
--
-- Por eso se reescribe: ahora el pago confirmado crea la venta, y es la venta
-- la que mueve el stock. Un solo camino, y el movimiento queda atado a su
-- venta como cualquier otro del ERP.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1) Seguimiento del envío
-- -----------------------------------------------------------------------------
alter table manastina.web_pedidos
  add column if not exists estado_envio text not null default 'pendiente';

alter table manastina.web_pedidos
  add column if not exists preparando_at timestamptz;
alter table manastina.web_pedidos
  add column if not exists enviado_at    timestamptz;
alter table manastina.web_pedidos
  add column if not exists entregado_at  timestamptz;

-- Para que quien despacha pueda dejar anotado lo que haga falta.
alter table manastina.web_pedidos
  add column if not exists notas_internas text;

do $$
begin
  alter table manastina.web_pedidos
    add constraint web_pedidos_estado_envio_valido
    check (estado_envio in ('pendiente','preparando','enviado','entregado','cancelado'));
exception when duplicate_object then
  null;
end $$;

comment on column manastina.web_pedidos.estado_envio is
  'Como va la entrega: pendiente, preparando, enviado, entregado o cancelado.';

create index if not exists web_pedidos_envio_idx
  on manastina.web_pedidos (estado_envio, created_at desc);


-- -----------------------------------------------------------------------------
-- 2) Marca de origen en las ventas
-- -----------------------------------------------------------------------------
-- Es lo que le permite a la pantalla de ventas mostrar el chip "Web".
-- Las ventas del mostrador quedan en null, como estaban.
alter table manastina.ventas
  add column if not exists origen     text;
alter table manastina.ventas
  add column if not exists origen_ref text;

comment on column manastina.ventas.origen is
  'De donde vino la venta: null = mostrador, ''web'' = tienda online.';
comment on column manastina.ventas.origen_ref is
  'Identificador en el sistema de origen. Para la web, el numero de pedido.';

create index if not exists ventas_origen_idx
  on manastina.ventas (origen) where origen is not null;


-- -----------------------------------------------------------------------------
-- 3) Cambiar el estado del envío
-- -----------------------------------------------------------------------------
create or replace function manastina.web_marcar_envio(
  p_pedido uuid,
  p_estado text,
  p_nota   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = manastina, public
as $$
declare
  v_estado text := lower(trim(p_estado));
begin
  if v_estado not in ('pendiente','preparando','enviado','entregado','cancelado') then
    return jsonb_build_object('ok', false, 'error', 'estado no valido: ' || p_estado);
  end if;

  update manastina.web_pedidos
     set estado_envio   = v_estado,
         preparando_at  = case when v_estado = 'preparando' then coalesce(preparando_at, now()) else preparando_at end,
         enviado_at     = case when v_estado = 'enviado'    then coalesce(enviado_at, now())    else enviado_at end,
         entregado_at   = case when v_estado = 'entregado'  then coalesce(entregado_at, now())  else entregado_at end,
         notas_internas = coalesce(nullif(trim(coalesce(p_nota, '')), ''), notas_internas)
   where id = p_pedido;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'pedido no encontrado');
  end if;

  return jsonb_build_object('ok', true, 'estado_envio', v_estado);
end $$;

comment on function manastina.web_marcar_envio(uuid, text, text) is
  'Cambia el estado de entrega de un pedido web y anota la fecha del cambio.';


-- -----------------------------------------------------------------------------
-- 4) El pago confirmado crea la venta
-- -----------------------------------------------------------------------------
create or replace function manastina.web_confirmar_pedido(p_pedido uuid)
returns jsonb
language plpgsql
security definer
set search_path = manastina, public
as $$
declare
  v_pedido    record;
  v_item      record;
  v_empresa   uuid;
  v_venta     uuid;
  v_numero    text;
  v_sin_link  int := 0;
  v_lineas    int := 0;
  v_faltantes jsonb := '[]'::jsonb;
  v_subtotal  bigint := 0;
  v_iva       bigint := 0;
  v_total     bigint := 0;
  v_lin_iva   bigint;
  v_lin_sub   bigint;
begin
  select * into v_pedido
    from manastina.web_pedidos
   where id = p_pedido
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'pedido no encontrado');
  end if;

  if v_pedido.estado_pago <> 'pagado' then
    return jsonb_build_object('ok', false, 'error', 'el pedido no esta pagado',
                              'estado', v_pedido.estado_pago);
  end if;

  -- Ya procesado. Esto es lo que vuelve seguro que PagoPar reintente el aviso.
  if v_pedido.stock_descontado_at is not null then
    return jsonb_build_object('ok', true, 'repetido', true,
                              'venta_id', v_pedido.venta_id,
                              'procesado_at', v_pedido.stock_descontado_at);
  end if;

  -- La empresa sale de la base, no de la configuracion: asi no depende de que
  -- alguien se acuerde de cargar una variable de entorno.
  v_empresa := v_pedido.empresa_id;
  if v_empresa is null then
    select id into v_empresa from manastina.empresas order by created_at limit 1;
    if v_empresa is null then
      return jsonb_build_object('ok', false, 'error', 'no hay empresa cargada');
    end if;
    update manastina.web_pedidos set empresa_id = v_empresa where id = p_pedido;
  end if;

  perform manastina.web_vincular_items(p_pedido);

  -- --- Se revisa que TODAS las lineas tengan su producto -------------------
  -- Una venta a medias descuadraria el inventario y la contabilidad, asi que
  -- si falta aunque sea una, no se crea nada y queda marcado para revisar.
  for v_item in
    select d.producto_codigo, d.nombre, d.cantidad
      from manastina.web_pedido_items d
     where d.pedido_id = p_pedido and d.producto_id is null
  loop
    v_sin_link := v_sin_link + 1;
    v_faltantes := v_faltantes || jsonb_build_object(
      'codigo', v_item.producto_codigo, 'nombre', v_item.nombre,
      'cantidad', v_item.cantidad);
  end loop;

  if v_sin_link > 0 then
    update manastina.web_pedidos
       set notas_internas = coalesce(notas_internas || E'\n', '') ||
           'No se pudo crear la venta: ' || v_sin_link ||
           ' producto(s) del pedido no existen en el inventario.'
     where id = p_pedido;

    return jsonb_build_object('ok', false, 'error', 'hay lineas sin producto en el ERP',
                              'lineas_sin_producto', v_sin_link,
                              'faltantes', v_faltantes);
  end if;

  -- --- Totales -------------------------------------------------------------
  -- Los precios de la tienda ya llevan el IVA adentro, como es habitual acá.
  -- Con IVA 10%: el impuesto es la onceava parte del total.
  select coalesce(sum(total_linea), 0) into v_total
    from manastina.web_pedido_items where pedido_id = p_pedido;

  -- El envio cobrado online tambien es parte de la venta.
  v_total := v_total + coalesce(v_pedido.envio, 0);
  v_iva := round(v_total / 11.0);
  v_subtotal := v_total - v_iva;

  -- --- Numero de control, con el mismo formato que usa el ERP --------------
  select 'VTA-' || lpad(
           (coalesce(max(
             case when numero_control ~ '^VTA-[0-9]+$'
                  then substring(numero_control from '[0-9]+$')::bigint
                  else null::bigint end), 0) + 1)::text, 6, '0')
    into v_numero
    from manastina.ventas
   where empresa_id = v_empresa;

  -- --- La venta ------------------------------------------------------------
  insert into manastina.ventas (
    empresa_id, cliente_id, numero_control, moneda, tipo_cambio,
    subtotal, monto_iva, total, estado, tipo_venta, fecha, observaciones,
    cliente_nombre_libre, cliente_telefono_libre,
    origen, origen_ref
  ) values (
    v_empresa, v_pedido.cliente_id, v_numero, 'GS', 1,
    v_subtotal, v_iva, v_total, 'completada', 'CONTADO', now(),
    'Pedido web #' || v_pedido.id_pedido_comercio ||
      case when v_pedido.modalidad = 'retiro' then ' · retira en el local'
           else ' · envio a ' || coalesce(v_pedido.ciudad_nombre, 'coordinar') end,
    v_pedido.cliente_nombre, v_pedido.cliente_telefono,
    'web', v_pedido.id_pedido_comercio::text
  )
  returning id into v_venta;

  -- --- Las lineas, el stock y su movimiento --------------------------------
  for v_item in
    select d.*, p.nombre as pnombre, p.sku as psku, p.costo_promedio
      from manastina.web_pedido_items d
      join manastina.productos p on p.id = d.producto_id
     where d.pedido_id = p_pedido
  loop
    v_lin_iva := round(v_item.total_linea / 11.0);
    v_lin_sub := v_item.total_linea - v_lin_iva;

    insert into manastina.ventas_items (
      empresa_id, venta_id, producto_id, producto_nombre, sku,
      cantidad, precio_venta_original, precio_venta, tipo_iva,
      subtotal, monto_iva, total_linea
    ) values (
      v_empresa, v_venta, v_item.producto_id, v_item.pnombre, v_item.psku,
      v_item.cantidad, v_item.precio_unitario, v_item.precio_unitario, '10%',
      v_lin_sub, v_lin_iva, v_item.total_linea
    );

    update manastina.productos
       set stock_actual = greatest(0, coalesce(stock_actual, 0) - v_item.cantidad),
           updated_at   = now()
     where id = v_item.producto_id;

    insert into manastina.movimientos_inventario (
      empresa_id, producto_id, producto_nombre, producto_sku,
      tipo, cantidad, costo_unitario, origen, referencia, fecha, venta_id
    ) values (
      v_empresa, v_item.producto_id, v_item.pnombre, v_item.psku,
      'SALIDA', v_item.cantidad, coalesce(v_item.costo_promedio, 0),
      'venta', v_numero, now(), v_venta
    );

    v_lineas := v_lineas + 1;
  end loop;

  update manastina.web_pedidos
     set venta_id            = v_venta,
         stock_descontado_at = now(),
         estado_envio        = case when estado_envio = 'pendiente'
                                    then 'preparando' else estado_envio end,
         preparando_at       = coalesce(preparando_at, now())
   where id = p_pedido;

  return jsonb_build_object(
    'ok', true,
    'venta_id', v_venta,
    'numero_control', v_numero,
    'lineas', v_lineas,
    'total', v_total
  );
end $$;

comment on function manastina.web_confirmar_pedido(uuid) is
  'Convierte un pedido web pagado en una venta del ERP, con su stock y su movimiento. Idempotente.';


-- -----------------------------------------------------------------------------
-- 5) La vista, con lo nuevo
-- -----------------------------------------------------------------------------
drop view if exists manastina.v_web_pedidos;

create view manastina.v_web_pedidos as
select
  p.id,
  p.id_pedido_comercio                              as numero_pedido,
  p.empresa_id,

  p.estado_pago,
  (p.estado_pago = 'pagado')                        as esta_pagado,
  p.pagado_at,
  p.created_at                                      as fecha_pedido,

  p.estado_envio,
  p.preparando_at,
  p.enviado_at,
  p.entregado_at,
  p.notas_internas,

  p.envio_aparte                                    as cobrar_envio_al_entregar,

  p.cliente_nombre,
  p.cliente_telefono,
  p.cliente_email,
  p.cliente_documento,

  case
    when p.cliente_telefono ~ '^595'    then p.cliente_telefono
    when p.cliente_telefono ~ '^0'      then '595' || substring(p.cliente_telefono from 2)
    when length(p.cliente_telefono) = 9 then '595' || p.cliente_telefono
    else p.cliente_telefono
  end                                               as whatsapp_numero,

  'https://wa.me/' ||
    case
      when p.cliente_telefono ~ '^595'    then p.cliente_telefono
      when p.cliente_telefono ~ '^0'      then '595' || substring(p.cliente_telefono from 2)
      when length(p.cliente_telefono) = 9 then '595' || p.cliente_telefono
      else p.cliente_telefono
    end ||
    '?text=Hola,%20te%20escribimos%20de%20MANASTINA%20por%20tu%20pedido%20%23'
    || p.id_pedido_comercio                         as whatsapp_link,

  p.modalidad,
  p.ciudad_codigo                                   as ciudad_clave,
  p.ciudad_nombre,
  p.direccion,
  p.direccion_referencia,
  p.observaciones,

  p.subtotal,
  p.envio                                           as envio_cobrado,
  p.total                                           as total_cobrado,
  p.envio_estimado                                  as envio_tarifa,
  case when p.envio_aparte then p.envio_estimado else 0 end
                                                    as envio_a_cobrar,

  coalesce(i.cantidad_articulos, 0)                 as cantidad_articulos,
  coalesce(i.resumen, '')                           as detalle,
  coalesce(i.items, '[]'::jsonb)                    as items,

  p.venta_id,
  v.numero_control                                  as venta_numero,
  p.cliente_id,
  p.pagopar_hash,
  p.pagopar_forma_pago                              as forma_pago

from manastina.web_pedidos p
left join manastina.ventas v on v.id = p.venta_id
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
  'Pedidos de la tienda web para el ERP: cliente, entrega, detalle, cobro, estado del envio y la venta asociada.';


-- -----------------------------------------------------------------------------
-- 6) Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select on manastina.v_web_pedidos to service_role;
grant select, insert, update on manastina.web_pedidos      to service_role;
grant select, insert, update on manastina.web_pedido_items to service_role;

grant execute on function manastina.web_confirmar_pedido(uuid)            to service_role;
grant execute on function manastina.web_marcar_envio(uuid, text, text)    to service_role;
grant execute on function manastina.web_vincular_items(uuid)              to service_role;

notify pgrst, 'reload schema';
