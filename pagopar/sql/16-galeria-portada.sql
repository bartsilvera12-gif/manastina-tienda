-- =============================================================================
-- MANASTINA · La galería de la portada, manejada desde el ERP
-- =============================================================================
-- Correr después del 15.
--
-- La banda "Galería" de la portada tenía sus diez fotos y videos escritos en el
-- archivo del sitio. Con esto se manejan desde el ERP: se agregan, se sacan, se
-- reordenan y se les cambia el título sin tocar código.
--
-- Al final quedan cargados los diez que ya estaban, con su título y su texto,
-- apuntando a los archivos del sitio. Se pueden reemplazar de a uno cuando
-- quieran, subiendo el archivo nuevo desde el módulo.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- La galería
-- -----------------------------------------------------------------------------
create table if not exists manastina.galeria_web (
  id                 uuid primary key default gen_random_uuid(),
  empresa_id         uuid        not null,

  -- 'foto' o 'video'. Los videos se reproducen solos, sin sonido.
  tipo               text        not null default 'foto'
                                 check (tipo in ('foto', 'video')),

  titulo             text,
  descripcion        text,

  -- El archivo dentro del bucket privado. Puede estar vacío en los que vienen
  -- del sitio: esos ya tienen su dirección pública cargada abajo.
  imagen_path        text,
  imagen_web_url     text,

  -- Portada del video: la imagen que se ve en la tira antes de reproducirlo.
  -- Solo para los videos; en las fotos queda vacía.
  miniatura_path     text,
  miniatura_web_url  text,

  orden              integer     not null default 0,
  activo             boolean     not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table manastina.galeria_web is
  'Fotos y videos de la banda Galeria de la portada. Se manejan desde el modulo Galeria del ERP.';
comment on column manastina.galeria_web.imagen_web_url is
  'URL publica del archivo, generada automaticamente. No editar a mano.';
comment on column manastina.galeria_web.miniatura_web_url is
  'URL publica de la portada del video, generada automaticamente. No editar a mano.';

create index if not exists galeria_web_orden_idx
  on manastina.galeria_web (orden) where activo;

-- Cambiar el archivo tiene que verse en la web: mismo disparador que el resto.
drop trigger if exists galeria_web_refrescar on manastina.galeria_web;
create trigger galeria_web_refrescar
  before update of imagen_path on manastina.galeria_web
  for each row execute function manastina.web_refrescar_imagen();

-- Y lo mismo para la portada del video, que vive en otra columna.
create or replace function manastina.web_refrescar_miniatura()
returns trigger
language plpgsql
as $fn$
begin
  if new.miniatura_path is distinct from old.miniatura_path then
    new.miniatura_web_url := null;
  end if;
  return new;
end;
$fn$;

drop trigger if exists galeria_web_refrescar_min on manastina.galeria_web;
create trigger galeria_web_refrescar_min
  before update of miniatura_path on manastina.galeria_web
  for each row execute function manastina.web_refrescar_miniatura();


-- -----------------------------------------------------------------------------
-- Los diez que ya estaban en la web
-- -----------------------------------------------------------------------------
-- Con su título y su texto, apuntando a los archivos del sitio. No tienen
-- `imagen_path` porque el archivo no está en el bucket: vive en la carpeta del
-- sitio. Se pueden reemplazar de a uno subiendo el archivo nuevo.
--
-- Solo se cargan si la galería está vacía, para no duplicarlos al volver a
-- correr el script.
insert into manastina.galeria_web
  (empresa_id, tipo, titulo, descripcion, imagen_web_url, miniatura_web_url, orden)
select e.empresa_id, g.tipo, g.titulo, g.descripcion, g.url, g.thumb, g.orden
  from (select distinct empresa_id from manastina.productos) e
 cross join (values
   ('foto',  'Campaña',         'Estructura firme, terminación serena.', 'assets/hero-1.png',        null,                      1),
   ('video', 'En movimiento',   'Detalle de la pieza.',                  'assets/gal-vid-1.mp4',     'assets/gal-vid-1.jpg',    2),
   ('foto',  'Nuestro local',   'Te esperamos en Capiatá.',              'assets/sobre-tienda.jpg',  null,                      3),
   ('video', 'Selección',       'Piezas en video.',                      'assets/gal-vid-2.mp4',     'assets/gal-vid-2.jpg',    4),
   ('foto',  'Nuevos ingresos', 'En cantidades cortas.',                 'assets/hero-3.png',        null,                      5),
   ('foto',  'Carteras',        'Cuero con presencia.',                  'assets/gal-bolsos.jpg',    null,                      6),
   ('video', 'En la tienda',    'Recorré la selección.',                 'assets/gal-vid-3.mp4',     'assets/gal-vid-3.jpg',    7),
   ('foto',  'Bandoleras',      'Para cada ocasión.',                    'assets/gal-bolsos.jpg',    null,                      8),
   ('video', 'Detalle',         'Terminaciones.',                        'assets/gal-vid-4.mp4',     'assets/gal-vid-4.jpg',    9),
   ('foto',  'Accesorios',      'Selección Manastina.',                  'assets/sobre-tienda.jpg',  null,                     10)
 ) as g(tipo, titulo, descripcion, url, thumb, orden)
 where not exists (select 1 from manastina.galeria_web);


-- -----------------------------------------------------------------------------
-- Lo que la tienda necesita
-- -----------------------------------------------------------------------------
drop view if exists manastina.v_web_galeria;

create view manastina.v_web_galeria as
select
  g.id            as galeria_id,
  g.tipo,
  g.titulo,
  g.descripcion,
  g.imagen_path,
  g.imagen_web_url,
  g.miniatura_path,
  g.miniatura_web_url,
  g.orden,
  g.empresa_id
from manastina.galeria_web g
where g.activo
order by g.orden, g.created_at;

comment on view manastina.v_web_galeria is
  'Fotos y videos publicados de la galeria de la portada, en su orden.';


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select on manastina.v_web_galeria to service_role;
grant select, insert, update, delete on manastina.galeria_web to service_role;

notify pgrst, 'reload schema';
