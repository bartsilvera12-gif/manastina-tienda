-- =============================================================================
-- MANASTINA · Colecciones de la portada, manejadas desde el ERP
-- =============================================================================
-- Correr después del 11.
--
-- La portada tiene un bloque grande —"Nueva colección / Presencia en cada
-- detalle"— con una foto de campaña y un botón "Descubrir". Hasta ahora el
-- nombre, la frase y la foto estaban escritos en el archivo del sitio.
--
-- Con esto pasan a salir del ERP: se arma la colección, se le eligen los
-- productos del inventario, se le sube la foto, y el botón "Descubrir" lleva
-- al catálogo filtrado justo por esos productos.
--
-- Todo lo que se crea acá es nuevo. No toca ninguna tabla existente salvo por
-- un disparador que arregla el refresco de las fotos (ver más abajo).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- La colección
-- -----------------------------------------------------------------------------
create table if not exists manastina.colecciones_web (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid        not null,

  -- Lo que se lee arriba del todo, en letra chica: "Nueva colección".
  nombre         text        not null,

  -- El slug con el que la tienda la identifica en el catálogo.
  slug           text        not null,

  -- La frase grande: "Presencia en cada detalle". Si tiene un salto de línea,
  -- el sitio la parte ahí en dos renglones; si no, la parte sola por el medio.
  frase          text,

  -- Foto de campaña. `imagen_path` es la ruta en el bucket privado, la misma
  -- convención que productos. `imagen_web_url` la completa sola la Edge
  -- Function cuando la copia al bucket público: no editar a mano.
  imagen_path    text,
  imagen_web_url text,

  -- La que se muestra en la portada. Solo puede haber una por empresa.
  activa         boolean     not null default false,

  orden          integer     not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

comment on table manastina.colecciones_web is
  'Colecciones de la portada de la tienda. Se arman desde el modulo Colecciones del ERP.';
comment on column manastina.colecciones_web.frase is
  'Frase grande de la portada. Un salto de linea la parte en dos renglones.';
comment on column manastina.colecciones_web.imagen_web_url is
  'URL publica de la foto, generada automaticamente. No editar a mano.';

create unique index if not exists colecciones_web_slug_idx
  on manastina.colecciones_web (empresa_id, slug);

-- Garantiza que la portada nunca tenga dos colecciones peleando el lugar.
create unique index if not exists colecciones_web_una_activa_idx
  on manastina.colecciones_web (empresa_id)
  where activa;


-- -----------------------------------------------------------------------------
-- Qué productos la componen
-- -----------------------------------------------------------------------------
create table if not exists manastina.colecciones_web_productos (
  coleccion_id uuid    not null references manastina.colecciones_web (id) on delete cascade,
  producto_id  uuid    not null references manastina.productos (id)       on delete cascade,
  orden        integer not null default 0,
  primary key (coleccion_id, producto_id)
);

comment on table manastina.colecciones_web_productos is
  'Productos que integran cada coleccion. El orden manda como salen en el catalogo.';

create index if not exists colecciones_web_productos_prod_idx
  on manastina.colecciones_web_productos (producto_id);


-- -----------------------------------------------------------------------------
-- Que cambiar la foto se vea en la web
-- -----------------------------------------------------------------------------
-- La Edge Function copia la foto del bucket privado al público una sola vez y
-- guarda la dirección en `imagen_web_url`. Mientras esa dirección esté puesta,
-- no vuelve a copiar nada.
--
-- Sin esto, subir una foto nueva desde el ERP no cambiaba nada en la tienda:
-- seguía sirviendo la copia vieja para siempre. El disparador borra la
-- dirección cuando la foto cambia, y así la próxima visita la vuelve a copiar.
-- -----------------------------------------------------------------------------
create or replace function manastina.web_refrescar_imagen()
returns trigger
language plpgsql
as $fn$
begin
  if new.imagen_path is distinct from old.imagen_path then
    new.imagen_web_url := null;
  end if;
  return new;
end;
$fn$;

comment on function manastina.web_refrescar_imagen() is
  'Al cambiar la foto, borra la copia publica para que la tienda la genere de nuevo.';

drop trigger if exists productos_refrescar_imagen on manastina.productos;
create trigger productos_refrescar_imagen
  before update of imagen_path on manastina.productos
  for each row execute function manastina.web_refrescar_imagen();

drop trigger if exists categorias_refrescar_imagen on manastina.categorias_productos;
create trigger categorias_refrescar_imagen
  before update of imagen_path on manastina.categorias_productos
  for each row execute function manastina.web_refrescar_imagen();

drop trigger if exists colecciones_refrescar_imagen on manastina.colecciones_web;
create trigger colecciones_refrescar_imagen
  before update of imagen_path on manastina.colecciones_web
  for each row execute function manastina.web_refrescar_imagen();


-- -----------------------------------------------------------------------------
-- Lo que la tienda necesita saber
-- -----------------------------------------------------------------------------
-- Solo sale la colección activa, y solo con los productos que además estén
-- publicados: si sacaron uno de la web, deja de contar para la colección sin
-- que nadie tenga que acordarse de editarla.
--
-- Los códigos salen de `v_web_catalogo`, que es la misma vista que arma el
-- catálogo. Así el filtro del botón "Descubrir" no puede quedar desalineado
-- con lo que la tienda realmente muestra.
-- -----------------------------------------------------------------------------
drop view if exists manastina.v_web_colecciones;

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


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select on manastina.v_web_colecciones to service_role;
grant select, insert, update, delete on manastina.colecciones_web           to service_role;
grant select, insert, update, delete on manastina.colecciones_web_productos to service_role;

notify pgrst, 'reload schema';
