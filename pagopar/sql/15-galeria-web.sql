-- =============================================================================
-- MANASTINA · Galería de fotos de cada producto en la tienda
-- =============================================================================
-- Correr después del 13, y DESPUÉS de la migración
-- `20260827220000_producto_imagenes.sql` del ERP, que crea la tabla.
--
-- La ficha de producto de la tienda ya sabía mostrar varias fotos, pero las
-- leía del archivo del sitio. Con esto salen del ERP: la portada es la foto
-- principal del producto y las que siguen se cargan en la galería.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- La columna de la web
-- -----------------------------------------------------------------------------
-- La completa sola la Edge Function cuando copia la foto del bucket privado al
-- público. No editar a mano.
alter table manastina.producto_imagenes
  add column if not exists imagen_web_url text;

comment on column manastina.producto_imagenes.imagen_web_url is
  'URL publica de la foto, generada automaticamente. No editar a mano.';

-- Cambiar una foto tiene que verse en la web: mismo disparador que el resto.
drop trigger if exists producto_imagenes_refrescar on manastina.producto_imagenes;
create trigger producto_imagenes_refrescar
  before update of imagen_path on manastina.producto_imagenes
  for each row execute function manastina.web_refrescar_imagen();


-- -----------------------------------------------------------------------------
-- Lo que la tienda necesita
-- -----------------------------------------------------------------------------
-- Solo de los productos publicados: si sacaron uno de la web, sus fotos dejan
-- de viajar sin que nadie tenga que acordarse de borrarlas.
drop view if exists manastina.v_web_producto_imagenes;

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
grant select on manastina.v_web_producto_imagenes to service_role;
grant select, insert, update, delete on manastina.producto_imagenes to service_role;

notify pgrst, 'reload schema';
