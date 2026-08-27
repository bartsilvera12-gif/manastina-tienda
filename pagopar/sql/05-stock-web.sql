-- =============================================================================
-- MANASTINA · Inventario compartido entre la web y el ERP
-- =============================================================================
-- Correr DESPUÉS de 04-productos-erp.sql.
--
-- Deja tres cosas:
--   1. v_web_catalogo  -> precio y stock reales, para que la web los muestre.
--   2. web_vincular_items -> ata cada línea del pedido con el producto del ERP.
--   3. web_confirmar_pedido -> descuenta el stock cuando el pago se confirma.
--
-- Sobre el descuento de stock: el ERP lleva los movimientos en
-- manastina.movimientos_inventario y actualiza productos.stock_actual desde la
-- aplicación, no con un trigger (ver saveMovimiento en neura-erp-manastia,
-- src/lib/inventario/storage.ts). Aun así la función mide el stock antes y
-- después de insertar el movimiento y solo lo ajusta si hizo falta: si algún
-- día agregan un trigger, esto sigue andando sin descontar dos veces.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Marca de idempotencia: el webhook de PagoPar puede llegar varias veces.
-- -----------------------------------------------------------------------------
alter table manastina.web_pedidos
  add column if not exists stock_descontado_at timestamptz;

comment on column manastina.web_pedidos.stock_descontado_at is
  'Cuándo se descontó el stock en el ERP. Si tiene valor, no se vuelve a descontar.';


-- -----------------------------------------------------------------------------
-- 1) Catálogo real, para que la web muestre precio y stock del ERP
-- -----------------------------------------------------------------------------
create or replace view manastina.v_web_catalogo as
select
  lower(replace(p.sku, 'MAN-', ''))  as codigo_web,   -- 'MAN-C01' -> 'c01'
  p.id                               as producto_id,
  p.sku,
  p.nombre,
  coalesce(p.precio_venta, 0)::bigint            as precio,
  greatest(0, coalesce(p.stock_actual, 0))::int  as stock,
  p.activo
from manastina.productos p
where p.sku like 'MAN-%';

comment on view manastina.v_web_catalogo is
  'Precio y stock reales de los productos de la tienda web. La Edge Function los sirve al sitio.';


-- -----------------------------------------------------------------------------
-- 2) Atar las líneas del pedido con los productos del ERP
-- -----------------------------------------------------------------------------
create or replace function manastina.web_vincular_items(p_pedido uuid)
returns int
language plpgsql
security definer
set search_path = manastina, public
as $$
declare
  n int;
begin
  update manastina.web_pedido_items d
     set producto_id = c.producto_id
    from manastina.v_web_catalogo c
   where d.pedido_id = p_pedido
     and d.producto_id is null
     and lower(d.producto_codigo) = c.codigo_web;

  get diagnostics n = row_count;
  return n;
end $$;

comment on function manastina.web_vincular_items(uuid) is
  'Completa producto_id en las lineas del pedido, cruzando por el codigo del catalogo web.';


-- -----------------------------------------------------------------------------
-- 3) Descontar el stock cuando el pago se confirma
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
  v_antes     numeric;
  v_despues   numeric;
  v_tipo      text;
  v_movidos   int := 0;
  v_sin_link  int := 0;
  v_faltantes jsonb := '[]'::jsonb;
begin
  select * into v_pedido
    from manastina.web_pedidos
   where id = p_pedido
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'pedido no encontrado');
  end if;

  -- Solo se descuenta si está pagado.
  if v_pedido.estado_pago <> 'pagado' then
    return jsonb_build_object('ok', false, 'error', 'el pedido no esta pagado',
                              'estado', v_pedido.estado_pago);
  end if;

  -- Ya se hizo: no repetir. Esto es lo que vuelve seguro reintentar el webhook.
  if v_pedido.stock_descontado_at is not null then
    return jsonb_build_object('ok', true, 'repetido', true,
                              'descontado_at', v_pedido.stock_descontado_at);
  end if;

  perform manastina.web_vincular_items(p_pedido);

  -- El ERP usa ENTRADA / SALIDA / AJUSTE en mayúsculas (ver TipoMovimiento en
  -- neura-erp-manastia, src/lib/inventario/types.ts). Se toma el valor que la
  -- tabla ya venga usando, y si está vacía, 'SALIDA'.
  select tipo into v_tipo
    from manastina.movimientos_inventario
   where upper(tipo) in ('SALIDA', 'EGRESO', 'OUT')
   order by created_at desc
   limit 1;

  v_tipo := coalesce(v_tipo, 'SALIDA');

  for v_item in
    select d.*, p.id as pid, p.nombre as pnombre, p.sku as psku,
           p.stock_actual, p.costo_promedio
      from manastina.web_pedido_items d
      left join manastina.productos p on p.id = d.producto_id
     where d.pedido_id = p_pedido
  loop
    if v_item.pid is null then
      -- El producto no está en el ERP: se anota y se sigue. No se aborta el
      -- pedido: la plata ya se cobró, esto se resuelve a mano.
      v_sin_link := v_sin_link + 1;
      v_faltantes := v_faltantes || jsonb_build_object(
        'codigo', v_item.producto_codigo, 'nombre', v_item.nombre,
        'cantidad', v_item.cantidad);
      continue;
    end if;

    v_antes := coalesce(v_item.stock_actual, 0);

    insert into manastina.movimientos_inventario (
      empresa_id, producto_id, producto_nombre, producto_sku,
      tipo, cantidad, costo_unitario, origen, referencia, fecha
    ) values (
      v_pedido.empresa_id, v_item.pid, v_item.pnombre, v_item.psku,
      v_tipo, v_item.cantidad, coalesce(v_item.costo_promedio, 0),
      -- origen solo admite compra | venta | ajuste_manual | inventario_inicial
      -- (OrigenMovimiento en el ERP). Una venta web es una venta; que vino de
      -- la tienda online queda dicho en la referencia.
      'venta', 'Tienda web · pedido #' || v_pedido.id_pedido_comercio, now()
    );

    -- ¿El trigger del ERP ya bajó el stock? Si no, lo bajamos nosotros.
    select coalesce(stock_actual, 0) into v_despues
      from manastina.productos where id = v_item.pid;

    if v_despues = v_antes then
      update manastina.productos
         set stock_actual = coalesce(stock_actual, 0) - v_item.cantidad,
             updated_at   = now()
       where id = v_item.pid;
    end if;

    v_movidos := v_movidos + 1;
  end loop;

  update manastina.web_pedidos
     set stock_descontado_at = now()
   where id = p_pedido;

  return jsonb_build_object(
    'ok', true,
    'lineas_descontadas', v_movidos,
    'lineas_sin_producto', v_sin_link,
    'faltantes', v_faltantes,
    'tipo_movimiento', v_tipo
  );
end $$;

comment on function manastina.web_confirmar_pedido(uuid) is
  'Descuenta en el ERP el stock de un pedido web pagado. Idempotente: si ya se hizo, no repite.';


-- -----------------------------------------------------------------------------
-- Permisos: solo la service_role (las Edge Functions). El navegador no entra.
-- -----------------------------------------------------------------------------
revoke all on function manastina.web_vincular_items(uuid)   from public, anon, authenticated;
revoke all on function manastina.web_confirmar_pedido(uuid) from public, anon, authenticated;
grant execute on function manastina.web_vincular_items(uuid)   to service_role;
grant execute on function manastina.web_confirmar_pedido(uuid) to service_role;
