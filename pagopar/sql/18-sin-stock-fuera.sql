-- =============================================================================
-- MANASTINA · Lo que no hay, no se muestra
-- =============================================================================
-- Correr después del 16.
--
-- Hasta ahora un producto sin stock seguía saliendo en la tienda con el cartel
-- "Agotado". Con esto directamente no viaja: si no hay unidades, no aparece.
--
-- Al salir de `v_web_catalogo` sale de todo lo que se apoya en ella —el
-- catálogo, las colecciones, sus fotos, y las cuentas de piezas por marca y
-- por categoría— sin tener que tocar nada más. Cuando vuelve a haber stock,
-- reaparece solo.
-- =============================================================================

-- No se baja la vista: se reemplaza en su lugar. Bajarla obliga a bajar antes
-- todo lo que se apoya en ella —`v_web_colecciones`, `v_web_producto_imagenes`—
-- y eso daba el error «cannot drop view ... because other objects depend on it».
-- Acá no cambia ninguna columna, solo se suma una condición, así que
-- `create or replace` alcanza y lo que cuelga de la vista se entera solo.
create or replace view manastina.v_web_catalogo as
select
  case
    when p.sku like 'MAN-%' then lower(replace(p.sku, 'MAN-', ''))
    else lower(p.sku)
  end                                            as codigo_web,
  p.id                                           as producto_id,
  p.sku,
  p.nombre,
  coalesce(p.precio_venta, 0)::bigint            as precio,
  greatest(0, coalesce(p.stock_actual, 0))::int  as stock,
  p.activo,
  p.descripcion_web,
  p.imagen_web_url,
  p.imagen_path,
  p.nuevo_web,
  p.destacado_web,
  p.empresa_id,
  c.nombre                                       as categoria_nombre,
  c.codigo                                       as categoria_codigo,
  mm.nombre                                      as marca_nombre
from manastina.productos p
left join manastina.categorias_productos c
       on c.id = p.categoria_principal_id
left join manastina.marcas mm
       on mm.id = p.marca_id
      and mm.activo
where p.visible_web
  and p.activo
  -- Sin unidades no se muestra. Vuelve solo cuando entra mercadería.
  and coalesce(p.stock_actual, 0) > 0;

comment on view manastina.v_web_catalogo is
  'Productos publicados y con stock. Manda el chip visible_web de manastina.productos.';


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select on manastina.v_web_catalogo to service_role;

notify pgrst, 'reload schema';


-- -----------------------------------------------------------------------------
-- Qué queda afuera con esta regla
-- -----------------------------------------------------------------------------
-- Para saber, antes de que alguien pregunte por qué no ve una pieza.
select p.sku, p.nombre, p.stock_actual
  from manastina.productos p
 where p.visible_web
   and p.activo
   and coalesce(p.stock_actual, 0) <= 0
 order by p.nombre;
