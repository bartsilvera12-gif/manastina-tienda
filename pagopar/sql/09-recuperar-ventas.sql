-- =============================================================================
-- MANASTINA · Completa el 07 y recupera las ventas que quedaron sin crear
-- =============================================================================
-- Correr si el 07 quedó a medias. Es idempotente: si ya está todo bien, no
-- cambia nada.
--
--   1. La función que convierte el pedido pagado en venta.
--   2. La recuperación de los pedidos que se pagaron cuando todavía corría la
--      versión vieja de esa función.
--   3. La vista con la venta asociada.
--
-- -----------------------------------------------------------------------------
-- Por qué la recuperación va aparte
-- -----------------------------------------------------------------------------
-- La versión vieja descontaba el stock por su cuenta y dejaba el pedido marcado
-- como procesado. Volver a llamar a la función normal no serviría: vería esa
-- marca y no haría nada. Y si se le sacara la marca, descontaría el stock por
-- segunda vez.
--
-- Por eso la recuperación crea la venta y sus líneas, ata el movimiento de
-- inventario que ya existe a esa venta, y NO toca el stock.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1) La función correcta
-- -----------------------------------------------------------------------------
create or replace function manastina.web_confirmar_pedido(p_pedido uuid)
returns jsonb
language plpgsql
security definer
set search_path = manastina, public
as $fn$
declare
  v_pedido    record;
  v_item      record;
  v_empresa   uuid;
  v_venta     uuid;
  v_numero    text;
  v_sin_link  int := 0;
  v_lineas    int := 0;
  v_faltantes jsonb := '[]'::jsonb;
  v_subtotal  bigint;
  v_iva       bigint;
  v_total     bigint;
  v_lin_iva   bigint;
  v_lin_sub   bigint;
begin
  select * into v_pedido from manastina.web_pedidos where id = p_pedido for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'pedido no encontrado');
  end if;

  if v_pedido.estado_pago <> 'pagado' then
    return jsonb_build_object('ok', false, 'error', 'el pedido no esta pagado',
                              'estado', v_pedido.estado_pago);
  end if;

  if v_pedido.stock_descontado_at is not null then
    return jsonb_build_object('ok', true, 'repetido', true,
                              'venta_id', v_pedido.venta_id,
                              'procesado_at', v_pedido.stock_descontado_at);
  end if;

  v_empresa := v_pedido.empresa_id;
  if v_empresa is null then
    select id into v_empresa from manastina.empresas order by created_at limit 1;
    if v_empresa is null then
      return jsonb_build_object('ok', false, 'error', 'no hay empresa cargada');
    end if;
    update manastina.web_pedidos set empresa_id = v_empresa where id = p_pedido;
  end if;

  perform manastina.web_vincular_items(p_pedido);

  for v_item in
    select d.producto_codigo, d.nombre, d.cantidad
      from manastina.web_pedido_items d
     where d.pedido_id = p_pedido and d.producto_id is null
  loop
    v_sin_link := v_sin_link + 1;
    v_faltantes := v_faltantes || jsonb_build_object(
      'codigo', v_item.producto_codigo, 'nombre', v_item.nombre, 'cantidad', v_item.cantidad);
  end loop;

  if v_sin_link > 0 then
    update manastina.web_pedidos
       set notas_internas = coalesce(notas_internas || chr(10), '') ||
           'No se pudo crear la venta: ' || v_sin_link ||
           ' producto(s) del pedido no existen en el inventario.'
     where id = p_pedido;
    return jsonb_build_object('ok', false, 'error', 'hay lineas sin producto en el ERP',
                              'lineas_sin_producto', v_sin_link, 'faltantes', v_faltantes);
  end if;

  select coalesce(sum(total_linea), 0) into v_total
    from manastina.web_pedido_items where pedido_id = p_pedido;
  v_total := v_total + coalesce(v_pedido.envio, 0);
  v_iva := round(v_total / 11.0);
  v_subtotal := v_total - v_iva;

  select 'VTA-' || lpad(
           (coalesce(max(
             case when numero_control ~ '^VTA-[0-9]+$'
                  then substring(numero_control from '[0-9]+$')::bigint
                  else null::bigint end), 0) + 1)::text, 6, '0')
    into v_numero
    from manastina.ventas where empresa_id = v_empresa;

  insert into manastina.ventas (
    empresa_id, cliente_id, numero_control, moneda, tipo_cambio,
    subtotal, monto_iva, total, estado, tipo_venta, fecha, observaciones,
    cliente_nombre_libre, cliente_telefono_libre, origen, origen_ref
  ) values (
    v_empresa, v_pedido.cliente_id, v_numero, 'GS', 1,
    v_subtotal, v_iva, v_total, 'completada', 'CONTADO', now(),
    'Pedido web #' || v_pedido.id_pedido_comercio ||
      case when v_pedido.modalidad = 'retiro' then ' - retira en el local'
           else ' - envio a ' || coalesce(v_pedido.ciudad_nombre, 'coordinar') end,
    v_pedido.cliente_nombre, v_pedido.cliente_telefono,
    'web', v_pedido.id_pedido_comercio::text
  )
  returning id into v_venta;

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

  return jsonb_build_object('ok', true, 'venta_id', v_venta,
                            'numero_control', v_numero, 'lineas', v_lineas, 'total', v_total);
end
$fn$;


-- -----------------------------------------------------------------------------
-- 2) Recuperación: la venta de un pedido ya procesado, SIN tocar el stock
-- -----------------------------------------------------------------------------
create or replace function manastina.web_venta_faltante(p_pedido uuid)
returns jsonb
language plpgsql
security definer
set search_path = manastina, public
as $fn$
declare
  v_pedido   record;
  v_item     record;
  v_empresa  uuid;
  v_venta    uuid;
  v_numero   text;
  v_lineas   int := 0;
  v_movs     int := 0;
  v_subtotal bigint;
  v_iva      bigint;
  v_total    bigint;
  v_lin_iva  bigint;
  v_lin_sub  bigint;
begin
  select * into v_pedido from manastina.web_pedidos where id = p_pedido for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'pedido no encontrado');
  end if;

  if v_pedido.estado_pago <> 'pagado' then
    return jsonb_build_object('ok', false, 'error', 'el pedido no esta pagado');
  end if;

  if v_pedido.venta_id is not null then
    return jsonb_build_object('ok', true, 'repetido', true, 'venta_id', v_pedido.venta_id);
  end if;

  v_empresa := v_pedido.empresa_id;
  if v_empresa is null then
    select id into v_empresa from manastina.empresas order by created_at limit 1;
    if v_empresa is null then
      return jsonb_build_object('ok', false, 'error', 'no hay empresa cargada');
    end if;
    update manastina.web_pedidos set empresa_id = v_empresa where id = p_pedido;
  end if;

  perform manastina.web_vincular_items(p_pedido);

  if exists (select 1 from manastina.web_pedido_items
              where pedido_id = p_pedido and producto_id is null) then
    return jsonb_build_object('ok', false,
      'error', 'hay lineas sin producto en el ERP; no se puede armar la venta');
  end if;

  select coalesce(sum(total_linea), 0) into v_total
    from manastina.web_pedido_items where pedido_id = p_pedido;
  v_total := v_total + coalesce(v_pedido.envio, 0);
  v_iva := round(v_total / 11.0);
  v_subtotal := v_total - v_iva;

  select 'VTA-' || lpad(
           (coalesce(max(
             case when numero_control ~ '^VTA-[0-9]+$'
                  then substring(numero_control from '[0-9]+$')::bigint
                  else null::bigint end), 0) + 1)::text, 6, '0')
    into v_numero
    from manastina.ventas where empresa_id = v_empresa;

  insert into manastina.ventas (
    empresa_id, cliente_id, numero_control, moneda, tipo_cambio,
    subtotal, monto_iva, total, estado, tipo_venta, fecha, observaciones,
    cliente_nombre_libre, cliente_telefono_libre, origen, origen_ref
  ) values (
    v_empresa, v_pedido.cliente_id, v_numero, 'GS', 1,
    v_subtotal, v_iva, v_total, 'completada', 'CONTADO',
    coalesce(v_pedido.pagado_at, v_pedido.created_at, now()),
    'Pedido web #' || v_pedido.id_pedido_comercio ||
      case when v_pedido.modalidad = 'retiro' then ' - retira en el local'
           else ' - envio a ' || coalesce(v_pedido.ciudad_nombre, 'coordinar') end,
    v_pedido.cliente_nombre, v_pedido.cliente_telefono,
    'web', v_pedido.id_pedido_comercio::text
  )
  returning id into v_venta;

  -- Las lineas de la venta. NO se toca el stock: ya lo descontó la versión vieja.
  for v_item in
    select d.*, p.nombre as pnombre, p.sku as psku
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
    v_lineas := v_lineas + 1;
  end loop;

  -- El movimiento de inventario ya existe, huérfano: se lo ata a esta venta.
  update manastina.movimientos_inventario
     set venta_id   = v_venta,
         referencia = v_numero
   where empresa_id = v_empresa
     and venta_id is null
     and referencia like '%pedido #' || v_pedido.id_pedido_comercio;

  get diagnostics v_movs = row_count;

  update manastina.web_pedidos
     set venta_id      = v_venta,
         estado_envio  = case when estado_envio = 'pendiente' then 'preparando' else estado_envio end,
         preparando_at = coalesce(preparando_at, now())
   where id = p_pedido;

  return jsonb_build_object('ok', true, 'venta_id', v_venta, 'numero_control', v_numero,
                            'lineas', v_lineas, 'movimientos_atados', v_movs,
                            'stock', 'sin cambios; ya se habia descontado');
end
$fn$;

comment on function manastina.web_venta_faltante(uuid) is
  'Crea la venta de un pedido web que se pago cuando la funcion vieja no las creaba. No toca el stock.';


-- -----------------------------------------------------------------------------
-- 3) Se corre la recuperación sobre lo que haya quedado pendiente
-- -----------------------------------------------------------------------------
do $rec$
declare
  r record;
  x jsonb;
  n int := 0;
begin
  for r in
    select id, id_pedido_comercio
      from manastina.web_pedidos
     where estado_pago = 'pagado' and venta_id is null
     order by created_at
  loop
    x := manastina.web_venta_faltante(r.id);
    n := n + 1;
    raise notice 'pedido #% -> %', r.id_pedido_comercio, x;
  end loop;

  if n = 0 then
    raise notice 'No habia pedidos pagados sin venta.';
  else
    raise notice 'Recuperados: %', n;
  end if;
end
$rec$;


-- -----------------------------------------------------------------------------
-- 4) La vista, con la venta asociada
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
      ' - ' order by d.nombre
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


-- -----------------------------------------------------------------------------
-- 5) Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select on manastina.v_web_pedidos to service_role;
grant execute on function manastina.web_venta_faltante(uuid) to service_role;
grant execute on function manastina.web_confirmar_pedido(uuid) to service_role;

notify pgrst, 'reload schema';
