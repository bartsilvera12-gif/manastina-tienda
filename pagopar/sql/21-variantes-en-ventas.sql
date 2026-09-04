-- =============================================================================
-- MANASTINA · Variantes de color en ventas, compras y movimientos
-- =============================================================================
-- Correr después del 20.
--
-- La migración 20 creó `producto_variantes` (cada color con su stock) y un
-- trigger que mantiene `productos.stock_actual = suma(variantes.stock)`. Pero
-- la venta del ERP todavía descontaba stock del producto entero: al vender
-- Rosa Amora "Negro" bajaba el total y el trigger, la próxima vez que se
-- tocaba una variante, recalculaba desde la suma y "revertía" la deducción.
--
-- Con esto se agrega `variante_id` a las tablas de líneas (ventas, compras,
-- movimientos). Cuando la línea trae variante, el ERP descuenta/agrega stock
-- sobre `producto_variantes.stock`; el trigger baja `stock_actual` sola.
-- Cuando no trae variante (producto sin colores cargados) sigue todo igual
-- que antes.
--
-- Aditiva: nullable + FK con `ON DELETE SET NULL`. Las líneas viejas no se
-- tocan, y borrar una variante no rompe el histórico —queda como venta a
-- "color desconocido".
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Líneas de venta
-- -----------------------------------------------------------------------------
alter table manastina.ventas_items
  add column if not exists variante_id uuid
    references manastina.producto_variantes(id) on delete set null;

create index if not exists ventas_items_variante_idx
  on manastina.ventas_items(variante_id);

comment on column manastina.ventas_items.variante_id is
  'Variante de color vendida en esta linea. NULL si el producto no tenia variantes cargadas al momento de la venta.';


-- -----------------------------------------------------------------------------
-- Movimientos de inventario
-- -----------------------------------------------------------------------------
-- Vale para SALIDA (venta), ENTRADA (compra, recepción) y AJUSTE. Cada
-- movimiento queda anclado a la variante que movió, si aplica.
alter table manastina.movimientos_inventario
  add column if not exists variante_id uuid
    references manastina.producto_variantes(id) on delete set null;

create index if not exists movimientos_inventario_variante_idx
  on manastina.movimientos_inventario(variante_id);

comment on column manastina.movimientos_inventario.variante_id is
  'Variante de color que se movio. NULL para movimientos de productos sin variantes o para ajustes globales del producto.';


-- -----------------------------------------------------------------------------
-- Líneas de compra y orden de compra
-- -----------------------------------------------------------------------------
-- Se agregan por simetría con ventas_items. La UI de compras las va a poder
-- usar cuando se implemente la carga de compras por variante; mientras tanto
-- las compras siguen entrando al total del producto (variante_id = NULL) sin
-- romper nada.
alter table manastina.compra_items
  add column if not exists variante_id uuid
    references manastina.producto_variantes(id) on delete set null;

create index if not exists compra_items_variante_idx
  on manastina.compra_items(variante_id);

alter table manastina.orden_compra_items
  add column if not exists variante_id uuid
    references manastina.producto_variantes(id) on delete set null;

create index if not exists orden_compra_items_variante_idx
  on manastina.orden_compra_items(variante_id);


-- -----------------------------------------------------------------------------
-- Pedidos de la tienda web
-- -----------------------------------------------------------------------------
-- La Edge Function `crear-pago` guarda cada linea del pedido con el nombre
-- del color como texto libre; ahora ademas resuelve ese nombre a la variante
-- del catalogo y lo persiste aca. Con esto la venta que Karen registra en el
-- ERP a partir del pedido web ya arranca con el variante_id correcto.
alter table manastina.web_pedido_items
  add column if not exists variante_id uuid
    references manastina.producto_variantes(id) on delete set null;

create index if not exists web_pedido_items_variante_idx
  on manastina.web_pedido_items(variante_id);


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
-- Las tablas ya tenían grants; los indices/columnas nuevas los heredan. No
-- hay nada que dar de nuevo.

notify pgrst, 'reload schema';


-- -----------------------------------------------------------------------------
-- Control
-- -----------------------------------------------------------------------------
-- Devuelve una fila por tabla con la columna nueva presente.
select table_name, column_name, is_nullable
  from information_schema.columns
 where table_schema = 'manastina'
   and column_name = 'variante_id'
   and table_name in (
     'ventas_items', 'movimientos_inventario',
     'compra_items', 'orden_compra_items',
     'web_pedido_items'
   )
 order by table_name;
