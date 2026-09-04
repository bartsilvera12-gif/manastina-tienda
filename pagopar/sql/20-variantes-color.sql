-- =============================================================================
-- MANASTINA · Variantes de color por producto
-- =============================================================================
-- Correr después del 19.
--
-- Hasta ahora un producto era un solo color: si el mismo modelo venía en tres
-- tonos había que crear tres productos, cada uno con sus fotos. Con esto un
-- producto puede tener varias variantes (color, hex, stock) y cada foto se
-- puede asignar a una variante; la ficha de la tienda cambia las fotos al
-- tocar el color, muestra el stock por variante y deshabilita las agotadas.
--
-- El stock total del producto pasa a ser la suma de sus variantes: un trigger
-- mantiene `productos.stock_actual` sincronizado sin que nadie tenga que
-- acordarse de sumar a mano. Los productos que todavía no tienen variantes
-- cargadas siguen igual que antes.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Tabla de variantes
-- -----------------------------------------------------------------------------
create table if not exists manastina.producto_variantes (
  id             uuid primary key default gen_random_uuid(),
  producto_id    uuid not null
                 references manastina.productos(id) on delete cascade,
  empresa_id     uuid not null,
  nombre         text not null,
  hex            text not null default '#1A1114',
  stock          integer not null default 0,
  orden          integer not null default 0,
  activo         boolean not null default true,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

comment on table manastina.producto_variantes is
  'Variantes de color de un producto. Cada una lleva su stock; las fotos se enganchan por variante_id en producto_imagenes.';

create unique index if not exists producto_variantes_prod_nombre_uk
  on manastina.producto_variantes(producto_id, lower(nombre));

create index if not exists producto_variantes_producto_idx
  on manastina.producto_variantes(producto_id, orden);


-- -----------------------------------------------------------------------------
-- Foto por variante
-- -----------------------------------------------------------------------------
-- Cuando `variante_id` está en NULL, la foto se comparte entre todas las
-- variantes (por ejemplo, un plano de la etiqueta o del interior). Con un id
-- apunta a la variante puntual: esa foto solo se muestra si el cliente elige
-- ese color. La portada del producto (`productos.imagen_web_url`) sigue
-- viviendo aparte, como hasta ahora.
alter table manastina.producto_imagenes
  add column if not exists variante_id uuid
    references manastina.producto_variantes(id) on delete set null;

comment on column manastina.producto_imagenes.variante_id is
  'Cuando esta cargada, la foto pertenece a esa variante de color. En NULL, aparece para todas las variantes.';

create index if not exists producto_imagenes_variante_idx
  on manastina.producto_imagenes(variante_id);


-- -----------------------------------------------------------------------------
-- El stock del producto = suma de sus variantes
-- -----------------------------------------------------------------------------
-- Cada vez que cambia una variante, se recalcula la suma y se guarda en
-- productos.stock_actual. Los productos sin variantes cargadas conservan su
-- stock manual: el trigger solo pisa el número cuando hay al menos una.
create or replace function manastina.web_recalcular_stock_producto()
returns trigger
language plpgsql
security definer
set search_path = manastina, public
as $$
declare
  pid   uuid;
  total integer;
  hay   integer;
begin
  pid := coalesce(new.producto_id, old.producto_id);

  select count(*), coalesce(sum(stock) filter (where activo), 0)
    into hay, total
    from manastina.producto_variantes
   where producto_id = pid;

  if hay > 0 then
    update manastina.productos
       set stock_actual = total
     where id = pid;
  end if;

  return null;
end;
$$;

drop trigger if exists producto_variantes_stock on manastina.producto_variantes;
create trigger producto_variantes_stock
  after insert or update or delete on manastina.producto_variantes
  for each row execute function manastina.web_recalcular_stock_producto();


-- -----------------------------------------------------------------------------
-- Vista para la tienda
-- -----------------------------------------------------------------------------
-- Devuelve, por cada variante publicada, sus fotos ya ordenadas. La Edge
-- Function las arma en `colores: [{ nombre, hex, stock, imagenes:[...] }]`.
drop view if exists manastina.v_web_producto_variantes;

create view manastina.v_web_producto_variantes as
select
  pv.id            as variante_id,
  pv.producto_id,
  v.codigo_web,
  pv.nombre,
  pv.hex,
  pv.stock,
  pv.orden,
  pv.empresa_id,
  coalesce(
    (select json_agg(
              json_build_object(
                'imagen_id',      pi.id,
                'imagen_path',    pi.imagen_path,
                'imagen_web_url', pi.imagen_web_url,
                'orden',          pi.orden
              ) order by pi.orden
            )
       from manastina.producto_imagenes pi
      where pi.variante_id = pv.id),
    '[]'::json
  ) as imagenes
from manastina.producto_variantes pv
join manastina.v_web_catalogo v on v.producto_id = pv.producto_id
where pv.activo
order by pv.producto_id, pv.orden, pv.nombre;

comment on view manastina.v_web_producto_variantes is
  'Variantes de color de los productos publicados, con sus fotos ya ordenadas.';


-- Se reemplaza la vista de galería para exponer también `variante_id`: así la
-- Edge Function distingue las fotos compartidas (NULL) de las que van a una
-- variante puntual.
drop view if exists manastina.v_web_producto_imagenes;

create view manastina.v_web_producto_imagenes as
select
  pi.id             as imagen_id,
  pi.producto_id,
  pi.variante_id,
  v.codigo_web,
  pi.imagen_path,
  pi.imagen_web_url,
  pi.orden,
  pi.empresa_id
from manastina.producto_imagenes pi
join manastina.v_web_catalogo v on v.producto_id = pi.producto_id
order by pi.producto_id, pi.orden;

comment on view manastina.v_web_producto_imagenes is
  'Fotos adicionales de los productos publicados, con la variante a la que pertenecen (NULL = compartida).';


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select, insert, update, delete on manastina.producto_variantes to service_role;
grant select on manastina.v_web_producto_variantes to service_role;
grant select on manastina.v_web_producto_imagenes to service_role;

notify pgrst, 'reload schema';
