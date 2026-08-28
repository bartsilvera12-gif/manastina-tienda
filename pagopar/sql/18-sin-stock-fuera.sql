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

drop view if exists manastina.v_web_producto_imagenes;
drop view if exists manastina.v_web_colecciones;
drop view if exists manastina.v_web_catalogo;

create view manastina.v_web_catalogo as
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


create view manastina.v_web_colecciones as
select
  c.id                                        as coleccion_id,
  c.slug                                      as clave,
  c.nombre,
  c.frase,
  c.imagen_web_url,
  c.imagen_path,
  c.orden,
  c.empresa_id,
  coalesce(p.codigos, array[]::text[])        as productos
from manastina.colecciones_web c
left join lateral (
  select array_agg(v.codigo_web order by cp.orden, v.nombre) as codigos
    from manastina.colecciones_web_productos cp
    join manastina.v_web_catalogo v on v.producto_id = cp.producto_id
   where cp.coleccion_id = c.id
) p on true
where c.activa
order by c.orden, c.nombre;

comment on view manastina.v_web_colecciones is
  'La coleccion que se muestra en la portada, con los codigos de sus productos publicados.';


create view manastina.v_web_producto_imagenes as
select
  pi.id             as imagen_id,
  pi.producto_id,
  v.codigo_web,
  pi.imagen_path,
  pi.imagen_web_url,
  pi.orden,
  pi.empresa_id
from manastina.producto_imagenes pi
join manastina.v_web_catalogo v on v.producto_id = pi.producto_id
order by pi.producto_id, pi.orden;

comment on view manastina.v_web_producto_imagenes is
  'Fotos adicionales de los productos publicados, en su orden.';


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select on manastina.v_web_catalogo          to service_role;
grant select on manastina.v_web_colecciones       to service_role;
grant select on manastina.v_web_producto_imagenes to service_role;

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
