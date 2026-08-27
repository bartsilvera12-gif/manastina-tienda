-- =============================================================================
-- MANASTINA · Categorías de la tienda, manejadas desde el ERP
-- =============================================================================
-- Correr después del 09.
--
-- Hasta ahora las categorías de la web estaban escritas en el archivo del
-- sitio. Con esto pasan a salir del ERP: se pueden crear, ocultar, reordenar
-- y cambiarles la foto sin tocar código ni volver a subir el sitio.
--
-- Todo es aditivo sobre `categorias_productos`, que ya existe.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Columnas nuevas
-- -----------------------------------------------------------------------------
alter table manastina.categorias_productos
  add column if not exists visible_web boolean not null default false;

-- Orden en que aparecen en la tienda. Más chico, más arriba.
alter table manastina.categorias_productos
  add column if not exists orden_web integer not null default 100;

-- Foto de la categoría en el sitio. La completa sola la Edge Function cuando
-- copia la imagen del bucket privado al público. No editar a mano.
alter table manastina.categorias_productos
  add column if not exists imagen_web_url text;

-- Ruta de la foto dentro del bucket privado, igual que en productos.
alter table manastina.categorias_productos
  add column if not exists imagen_path text;

comment on column manastina.categorias_productos.visible_web is
  'Si esta marcada, la categoria aparece en la tienda online.';
comment on column manastina.categorias_productos.orden_web is
  'Orden en la tienda. Mas chico, mas arriba.';
comment on column manastina.categorias_productos.imagen_web_url is
  'URL publica de la foto, generada automaticamente. No editar a mano.';

create index if not exists categorias_visible_web_idx
  on manastina.categorias_productos (visible_web, orden_web)
  where visible_web;


-- -----------------------------------------------------------------------------
-- Las cuatro que ya estaban en la web arrancan visibles, en su orden actual
-- -----------------------------------------------------------------------------
update manastina.categorias_productos
   set visible_web = true,
       orden_web   = case lower(codigo)
                       when 'carteras'   then 1
                       when 'bandoleras' then 2
                       when 'accesorios' then 3
                       when 'sets'       then 4
                       else 100
                     end
 where lower(codigo) in ('carteras', 'bandoleras', 'accesorios', 'sets')
   and visible_web = false;


-- -----------------------------------------------------------------------------
-- Lo que la tienda necesita saber de cada categoría
-- -----------------------------------------------------------------------------
-- Incluye cuántos productos publicados tiene: una categoría sin nada que
-- mostrar no debería ocupar un lugar en la portada.
-- -----------------------------------------------------------------------------
drop view if exists manastina.v_web_categorias;

create view manastina.v_web_categorias as
select
  lower(coalesce(nullif(c.codigo, ''), replace(lower(c.nombre), ' ', '-')))  as clave,
  c.id                                                                      as categoria_id,
  c.nombre,
  c.descripcion,
  c.orden_web,
  c.imagen_web_url,
  c.imagen_path,
  c.empresa_id,
  coalesce(p.publicados, 0)                                                 as productos
from manastina.categorias_productos c
left join lateral (
  select count(*) as publicados
    from manastina.productos pr
   where pr.categoria_principal_id = c.id
     and pr.visible_web
     and pr.activo
) p on true
where c.visible_web
  and c.activo
order by c.orden_web, c.nombre;

comment on view manastina.v_web_categorias is
  'Categorias publicadas en la tienda web, en su orden, con cuantos productos tiene cada una.';


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
grant select on manastina.v_web_categorias to service_role;

notify pgrst, 'reload schema';
