-- =============================================================================
-- MANASTINA · Marcas de la tienda, manejadas desde el ERP
-- =============================================================================
-- Correr después del 12, y DESPUÉS de la migración `20260827210000_marcas.sql`
-- del ERP, que es la que crea la tabla `marcas` y la columna `productos.marca_id`.
--
-- Hasta ahora la grilla "Las marcas que elegimos" tenía los nombres y los logos
-- escritos en el archivo del sitio. Con esto salen del ERP: se agregan marcas,
-- se les cambia el logo y se les asigna a cada producto desde el inventario.
--
-- Al final se dejan cargadas las siete marcas que ya estaban en la web, con sus
-- productos asignados, para no tener que rehacer ese trabajo a mano. Los logos
-- sí hay que volver a subirlos desde el ERP.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Columnas de la web sobre `marcas`
-- -----------------------------------------------------------------------------
-- `activo` ya viene de la migración del ERP y es lo que decide si la marca sale
-- en la tienda. Acá solo se agrega lo que es propio del sitio.

-- Orden en la grilla de la portada. Más chico, más a la izquierda.
alter table manastina.marcas
  add column if not exists orden_web integer not null default 100;

-- Ruta del logo dentro del bucket privado, igual que en productos.
alter table manastina.marcas
  add column if not exists imagen_path text;

-- URL pública del logo. La completa sola la Edge Function cuando lo copia al
-- bucket público. No editar a mano.
alter table manastina.marcas
  add column if not exists imagen_web_url text;

comment on column manastina.marcas.orden_web is
  'Orden en la grilla de marcas de la tienda. Mas chico, mas a la izquierda.';
comment on column manastina.marcas.imagen_web_url is
  'URL publica del logo, generada automaticamente. No editar a mano.';

create index if not exists marcas_orden_web_idx
  on manastina.marcas (orden_web, nombre) where activo;

-- Cambiar el logo tiene que verse en la web: mismo disparador que productos,
-- categorías y colecciones.
drop trigger if exists marcas_refrescar_imagen on manastina.marcas;
create trigger marcas_refrescar_imagen
  before update of imagen_path on manastina.marcas
  for each row execute function manastina.web_refrescar_imagen();


-- -----------------------------------------------------------------------------
-- Las siete marcas que ya estaban en la web
-- -----------------------------------------------------------------------------
-- En el mismo orden en que se venían mostrando. Si ya existen, no se tocan.
insert into manastina.marcas (empresa_id, nombre, slug, orden_web)
select e.empresa_id, m.nombre, m.slug, m.orden
  from (select distinct empresa_id from manastina.productos) e
 cross join (values
   ('Nine West',   'nine-west',   1),
   ('Prune',       'prune',       2),
   ('Guess',       'guess',       3),
   ('David Jones', 'david-jones', 4),
   ('Rosa Amora',  'rosa-amora',  5),
   ('Timberland',  'timberland',  6),
   ('Chrisbella',  'chrisbella',  7)
 ) as m(nombre, slug, orden)
on conflict (empresa_id, slug) do nothing;


-- -----------------------------------------------------------------------------
-- A cada producto, la marca que ya tenía en el sitio
-- -----------------------------------------------------------------------------
-- El reparto sale de datos-manastina.js, que es de donde la web las venía
-- leyendo. Solo se tocan los que todavía no tienen marca.
update manastina.productos p
   set marca_id = m.id
  from manastina.marcas m
 where m.empresa_id = p.empresa_id
   and p.marca_id is null
   and m.slug = case lower(replace(p.sku, 'MAN-', ''))
                  when 'c01' then 'chrisbella'
                  when 'c02' then 'chrisbella'
                  when 'c03' then 'chrisbella'
                  when 'c04' then 'david-jones'
                  when 'c05' then 'david-jones'
                  when 'c06' then 'david-jones'
                  when 'c07' then 'david-jones'
                  when 'c08' then 'guess'
                  when 'c09' then 'guess'
                  when 'c10' then 'guess'
                  when 'c11' then 'guess'
                  when 'c12' then 'nine-west'
                  when 'c13' then 'nine-west'
                  when 'c14' then 'nine-west'
                  when 'c15' then 'nine-west'
                  when 'c16' then 'prune'
                  when 'c17' then 'prune'
                  when 'c18' then 'prune'
                  when 'c19' then 'prune'
                  when 'c20' then 'rosa-amora'
                  when 'c21' then 'rosa-amora'
                  when 'c22' then 'rosa-amora'
                  when 'c23' then 'rosa-amora'
                  when 'c24' then 'timberland'
                  when 'c25' then 'timberland'
                  else null
                end;


-- -----------------------------------------------------------------------------
-- Lo que la tienda necesita saber de cada marca
-- -----------------------------------------------------------------------------
-- Con cuántos productos publicados tiene cada una: la web lo muestra debajo del
-- logo y una marca sin nada que mostrar no debería ocupar un lugar en la grilla.
drop view if exists manastina.v_web_marcas;

create view manastina.v_web_marcas as
select
  m.id                              as marca_id,
  m.slug                            as clave,
  m.nombre,
  m.imagen_web_url,
  m.imagen_path,
  m.orden_web,
  m.empresa_id,
  coalesce(p.publicados, 0)         as productos
from manastina.marcas m
left join lateral (
  select count(*) as publicados
    from manastina.productos pr
   where pr.marca_id = m.id
     and pr.visible_web
     and pr.activo
) p on true
where m.activo
order by m.orden_web, m.nombre;

comment on view manastina.v_web_marcas is
  'Marcas activas de la tienda, en su orden, con cuantos productos publicados tiene cada una.';


-- -----------------------------------------------------------------------------
-- El catálogo, ahora con la marca de cada pieza
-- -----------------------------------------------------------------------------
-- No se baja la vista: se reemplaza en su lugar. Bajarla obliga a bajar antes
-- todo lo que se apoya en ella —`v_web_colecciones`, `v_web_producto_imagenes`—
-- y ese fue el error «cannot drop view ... because other objects depend on it».
-- `create or replace` permite AGREGAR columnas al final dejando las anteriores
-- igual, que es justo lo que hace falta acá: se suma `marca_nombre`. Lo que
-- cuelga de la vista ni se entera, y pasa a ver la marca sin tocarlo.
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
  and p.activo;

comment on view manastina.v_web_catalogo is
  'Productos publicados en la tienda web. Manda el chip visible_web de manastina.productos.';


-- `v_web_colecciones` queda como estaba: lee de `v_web_catalogo`, así que se
-- entera sola de la marca nueva.


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select on manastina.v_web_catalogo    to service_role;
grant select on manastina.v_web_marcas      to service_role;
grant select, insert, update, delete on manastina.marcas to service_role;

notify pgrst, 'reload schema';
