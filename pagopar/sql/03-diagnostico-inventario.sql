-- =============================================================================
-- MANASTINA · Diagnóstico antes de unir el inventario del ERP con la web
-- =============================================================================
-- Esta consulta NO modifica nada. Solo lee.
--
-- Devuelve una tabla de dos columnas (dato / valor). Copiá el resultado y
-- pasámelo: con eso armo la integración sin romper nada del ERP.
--
-- Lo que necesito saber:
--   1. Cuál es el empresa_id de Manastina.
--   2. Si stock_actual lo mantiene un trigger desde movimientos_inventario,
--      o si la app lo escribe a mano. De esto depende TODO: si hay trigger,
--      la web tiene que registrar movimientos; si no, actualiza el producto.
--   3. Qué hay cargado hoy (productos, categorías, ubicaciones).
-- =============================================================================

select 'empresa_id' as dato,
       coalesce(string_agg(id::text || '  ->  ' || nombre_empresa, E'\n'), '(sin empresas)') as valor
from manastina.empresas

union all
select '--- TRIGGERS ---', ''

union all
select 'triggers en movimientos_inventario',
       coalesce(string_agg(t.tgname || '  ->  ' || p.proname, E'\n'), '(ninguno)')
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
join pg_proc p on p.oid = t.tgfoid
where n.nspname = 'manastina' and c.relname = 'movimientos_inventario' and not t.tgisinternal

union all
select 'triggers en productos',
       coalesce(string_agg(t.tgname || '  ->  ' || p.proname, E'\n'), '(ninguno)')
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
join pg_proc p on p.oid = t.tgfoid
where n.nspname = 'manastina' and c.relname = 'productos' and not t.tgisinternal

union all
select 'triggers en ventas_items',
       coalesce(string_agg(t.tgname || '  ->  ' || p.proname, E'\n'), '(ninguno)')
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
join pg_proc p on p.oid = t.tgfoid
where n.nspname = 'manastina' and c.relname = 'ventas_items' and not t.tgisinternal

union all
select '--- QUE HAY CARGADO ---', ''

union all
select 'productos', count(*)::text || ' (' || count(*) filter (where activo) || ' activos)'
from manastina.productos

union all
select 'ejemplos de producto',
       coalesce(string_agg(x.linea, E'\n'), '(ninguno)')
from (
  select coalesce(sku,'sin-sku') || ' | ' || nombre ||
         ' | precio ' || coalesce(precio_venta::text,'-') ||
         ' | stock ' || coalesce(stock_actual::text,'-') as linea
  from manastina.productos order by created_at desc limit 5
) x

union all
select 'valores de movimientos_inventario.tipo',
       coalesce(string_agg(distinct tipo, ', '), '(tabla vacia)')
from manastina.movimientos_inventario

union all
select 'valores de movimientos_inventario.origen',
       coalesce(string_agg(distinct origen, ', '), '(tabla vacia)')
from manastina.movimientos_inventario

union all
select 'categorias de producto',
       coalesce(string_agg(nombre, ', '), '(ninguna)')
from manastina.categorias_productos where activo

union all
select 'ubicaciones de inventario',
       coalesce(string_agg(nombre || case when tipo is not null then ' ('||tipo||')' else '' end, ', '), '(ninguna)')
from manastina.inventario_ubicaciones where activo

union all
select '--- COLUMNAS QUE NO PUEDO VER DESDE AFUERA ---', ''

union all
select 'columnas NOT NULL de productos sin default',
       coalesce(string_agg(column_name, ', '), '(ninguna)')
from information_schema.columns
where table_schema = 'manastina' and table_name = 'productos'
  and is_nullable = 'NO' and column_default is null

union all
select 'columnas NOT NULL de movimientos_inventario sin default',
       coalesce(string_agg(column_name, ', '), '(ninguna)')
from information_schema.columns
where table_schema = 'manastina' and table_name = 'movimientos_inventario'
  and is_nullable = 'NO' and column_default is null;
