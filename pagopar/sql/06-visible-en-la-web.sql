-- =============================================================================
-- MANASTINA · "Visible en la web" — el ERP decide qué se publica
-- =============================================================================
-- Correr DESPUÉS de 05-stock-web.sql.
--
-- Agrega a manastina.productos el chip que manda: si está marcado, el producto
-- sale en manastina.com; si no, queda solo en el inventario interno.
--
-- Todo es aditivo: no cambia ni borra nada de lo que el ERP ya usa.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Columnas nuevas en productos
-- -----------------------------------------------------------------------------
alter table manastina.productos
  add column if not exists visible_web boolean not null default false;

-- Texto que se muestra en la ficha de la tienda. Si está vacío, la web pone
-- un texto genérico. No se usa en ningún otro lado del ERP.
alter table manastina.productos
  add column if not exists descripcion_web text;

-- Dirección pública y permanente de la foto, para poder mostrarla en el sitio.
-- La completa sola la Edge Function `catalogo`: copia la imagen del bucket
-- privado del inventario a uno público la primera vez que hace falta.
-- No hace falta tocarla a mano.
alter table manastina.productos
  add column if not exists imagen_web_url text;

comment on column manastina.productos.visible_web is
  'Si esta marcado, el producto se publica en manastina.com.';
comment on column manastina.productos.descripcion_web is
  'Descripcion para la ficha de la tienda online. Opcional.';
comment on column manastina.productos.imagen_web_url is
  'URL publica de la foto, generada automaticamente. No editar a mano.';

create index if not exists productos_visible_web_idx
  on manastina.productos (visible_web)
  where visible_web;


-- -----------------------------------------------------------------------------
-- Los 25 productos que ya estaban en la web arrancan visibles
-- -----------------------------------------------------------------------------
update manastina.productos
   set visible_web = true
 where sku like 'MAN-%'
   and visible_web = false;


-- -----------------------------------------------------------------------------
-- El catálogo de la tienda pasa a definirse por el chip, no por el sku
-- -----------------------------------------------------------------------------
-- Antes solo entraban los que tenían sku 'MAN-...'. Ahora entra cualquier
-- producto marcado como visible, venga de donde venga.
--
-- `codigo_web` es con lo que la web identifica cada producto:
--   - 'MAN-C01' -> 'c01', para no romper los que ya existían.
--   - cualquier otro sku -> el sku en minúsculas.
-- -----------------------------------------------------------------------------
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
