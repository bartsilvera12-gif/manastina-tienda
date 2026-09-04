-- =============================================================================
-- MANASTINA · SKU y codigo de barras por variante
-- =============================================================================
-- Requerimiento de Manastina: cada color de un producto tiene su propio SKU y
-- su propio codigo de barras. Al escanear, el POS debe abrir la variante
-- puntual (no solo el producto general) y descontar del stock de esa variante.
--
-- Aditiva sobre la 20-variantes-color. Las columnas son opcionales: un
-- producto sin variantes o una variante que todavia no tiene SKU/barras
-- cargados sigue funcionando como hoy.
--
-- Correr despues de la 21.


-- -----------------------------------------------------------------------------
-- Columnas
-- -----------------------------------------------------------------------------
alter table manastina.producto_variantes
  add column if not exists sku            text,
  add column if not exists codigo_barras  text;

comment on column manastina.producto_variantes.sku is
  'SKU propio de esta variante. Opcional: si esta en NULL, se usa el del producto.';
comment on column manastina.producto_variantes.codigo_barras is
  'Codigo de barras propio de la variante. Al escanearlo, el POS abre esta variante puntual. Opcional.';


-- -----------------------------------------------------------------------------
-- Unicidad
-- -----------------------------------------------------------------------------
-- SKU y codigo de barras deben ser unicos por empresa cuando no son NULL.
-- Se usan indices unicos parciales: multiples variantes pueden dejar los
-- campos vacios sin chocarse, y una carga masiva puede aplicar por partes.

create unique index if not exists producto_variantes_sku_uk
  on manastina.producto_variantes(empresa_id, lower(sku))
 where sku is not null and length(trim(sku)) > 0;

create unique index if not exists producto_variantes_barras_uk
  on manastina.producto_variantes(empresa_id, codigo_barras)
 where codigo_barras is not null and length(trim(codigo_barras)) > 0;

-- Ademas, el codigo de barras de una variante NO puede chocar con el
-- codigo_barras del producto general (ni de otro producto). Se resuelve con
-- una funcion de chequeo compartida por trigger, para que sea un solo lugar
-- que decida "esto ya existe".
create or replace function manastina.check_barras_variante_no_choca()
returns trigger
language plpgsql
as $$
declare
  choca uuid;
begin
  if new.codigo_barras is null or length(trim(new.codigo_barras)) = 0 then
    return new;
  end if;

  select p.id into choca
    from manastina.productos p
   where p.empresa_id = new.empresa_id
     and p.codigo_barras = new.codigo_barras
   limit 1;

  if choca is not null then
    raise exception 'El codigo de barras % ya esta usado por un producto (id %).', new.codigo_barras, choca
      using errcode = '23505';
  end if;

  return new;
end;
$$;

drop trigger if exists check_barras_variante_no_choca on manastina.producto_variantes;
create trigger check_barras_variante_no_choca
before insert or update of codigo_barras on manastina.producto_variantes
for each row execute function manastina.check_barras_variante_no_choca();


-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------
notify pgrst, 'reload schema';


-- Control
select column_name, is_nullable, data_type
  from information_schema.columns
 where table_schema = 'manastina'
   and table_name   = 'producto_variantes'
   and column_name in ('sku', 'codigo_barras')
 order by column_name;
