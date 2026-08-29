-- =============================================================================
-- MANASTINA · Los contadores también miran el stock
-- =============================================================================
-- Correr después del 18.
--
-- El 18 sacó de la tienda lo que no tiene unidades, pero los contadores que
-- salen debajo de cada marca y de cada categoría siguieron contando igual:
-- una marca con tres carteras, todas en cero, seguía diciendo "3 piezas" y al
-- entrar no había nada. Peor: la grilla esconde lo que tiene cero, así que una
-- marca sin stock seguía ocupando un lugar que no le correspondía.
--
-- Con esto cuentan lo mismo que muestra el catálogo. Una marca o una categoría
-- sin unidades marca cero y sale de la grilla sola; cuando entra mercadería,
-- vuelve sola también.
-- =============================================================================

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
     -- Mismo criterio que v_web_catalogo: lo que no hay, no se cuenta.
     and coalesce(pr.stock_actual, 0) > 0
) p on true
where m.activo
order by m.orden_web, m.nombre;

comment on view manastina.v_web_marcas is
  'Marcas activas de la tienda, en su orden, con cuantas piezas disponibles tiene cada una.';


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
     and coalesce(pr.stock_actual, 0) > 0
) p on true
where c.visible_web
  and c.activo
order by c.orden_web, c.nombre;

comment on view manastina.v_web_categorias is
  'Categorias publicadas en la tienda web, en su orden, con cuantas piezas disponibles tiene cada una.';


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
grant usage on schema manastina to service_role;
grant select on manastina.v_web_marcas     to service_role;
grant select on manastina.v_web_categorias to service_role;

notify pgrst, 'reload schema';


-- -----------------------------------------------------------------------------
-- Qué queda en cero
-- -----------------------------------------------------------------------------
-- Las marcas y categorías que dejan de aparecer en la grilla por no tener
-- ninguna pieza disponible. Es para saber, no hay nada que arreglar acá: se
-- resuelve cargando stock.
select 'marca' as tipo, nombre, productos from manastina.v_web_marcas     where productos = 0
union all
select 'categoria',      nombre, productos from manastina.v_web_categorias where productos = 0
order by tipo, nombre;
