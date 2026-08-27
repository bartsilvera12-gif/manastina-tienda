-- =============================================================================
-- MANASTINA · Qué productos se destacan en la portada
-- =============================================================================
-- Correr después del 10.
--
-- La portada tiene dos secciones destacadas: "Nuevos ingresos" y la selección
-- de favoritos. Hasta ahora quién aparecía en cada una estaba escrito en el
-- archivo del sitio. Con esto se marca desde el ERP, igual que "Visible en la
-- web".
-- =============================================================================

alter table manastina.productos
  add column if not exists nuevo_web boolean not null default false;

alter table manastina.productos
  add column if not exists destacado_web boolean not null default false;

comment on column manastina.productos.nuevo_web is
  'Si esta marcado, el producto sale en "Nuevos ingresos" de la portada.';
comment on column manastina.productos.destacado_web is
  'Si esta marcado, el producto sale en la seleccion destacada de la portada.';

create index if not exists productos_nuevo_web_idx
  on manastina.productos (nuevo_web) where nuevo_web;


-- -----------------------------------------------------------------------------
-- Los cuatro más recientes arrancan como novedades
-- -----------------------------------------------------------------------------
-- Para que la sección no quede vacía la primera vez. Después se maneja desde
-- el ERP.
update manastina.productos
   set nuevo_web = true
 where id in (
   select id from manastina.productos
    where visible_web and activo
    order by created_at desc
    limit 4
 )
 and nuevo_web = false;


-- -----------------------------------------------------------------------------
-- La vista, con las dos marcas
-- -----------------------------------------------------------------------------
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
  c.codigo                                       as categoria_codigo
from manastina.productos p
left join manastina.categorias_productos c
       on c.id = p.categoria_principal_id
where p.visible_web
  and p.activo;

comment on view manastina.v_web_catalogo is
  'Productos publicados en la tienda web. Manda el chip visible_web de manastina.productos.';

grant select on manastina.v_web_catalogo to service_role;

notify pgrst, 'reload schema';
