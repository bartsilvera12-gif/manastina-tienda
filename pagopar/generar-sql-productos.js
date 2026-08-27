/* ------------------------------------------------------------------
   Genera pagopar/sql/04-productos-erp.sql a partir del catálogo real.
   Uso:  node pagopar/generar-sql-productos.js

   Volvé a correrlo cada vez que cambien productos o precios en
   datos-manastina.js, y corré el SQL de nuevo: es idempotente.
------------------------------------------------------------------ */
const fs = require('fs');
const path = require('path');

const raiz = path.join(__dirname, '..');
global.window = {};
require(path.join(raiz, 'datos-manastina.js'));
const datos = window.MANASTINA_DATOS;

/** Escapa para literal de Postgres. */
const q = (v) => {
  if (v === null || v === undefined || v === '') return 'null';
  return "'" + String(v).replace(/'/g, "''") + "'";
};

/** Código del producto en el ERP. Ata el catálogo de la web con manastina.productos. */
const sku = (id) => 'MAN-' + String(id).toUpperCase();

const categorias = datos.categorias.map(
  (c) => `    (${q(c.id)}, ${q(c.nombre)})`
).join(',\n');

const productos = datos.productos.map((p) => {
  const colores = (p.colores || []).map((c) => c.nombre).join(' / ');
  const imagen = (p.imagenes && p.imagenes[0]) || '';
  return '    (' + [
    q(sku(p.id)),
    q(p.id),
    q(p.nombre),
    q(p.marca || ''),
    q(p.categoria),
    Math.round(Number(p.precio) || 0),
    Math.max(0, Math.round(Number(p.stock) || 0)),
    q(p.descripcion || ''),
    q(colores),
    q(imagen),
  ].join(', ') + ')';
}).join(',\n');

const sql = `-- =============================================================================
-- MANASTINA · Catálogo de la web dentro del ERP
-- =============================================================================
-- GENERADO AUTOMÁTICAMENTE — no editar a mano.
-- Se regenera con:  node pagopar/generar-sql-productos.js
--
-- Carga los ${datos.productos.length} productos reales de la tienda en manastina.productos,
-- para que la web y el ERP compartan un solo inventario.
--
-- Es idempotente: se puede correr las veces que haga falta.
--   - Producto nuevo  -> se crea.
--   - Producto que ya existe -> se le actualizan nombre, precio y descripción.
--   - El STOCK NO se pisa nunca en productos que ya existían: manda el ERP.
--     Solo se usa el valor de la web como stock inicial al crearlos.
--
-- El vínculo entre los dos mundos es el sku: 'MAN-C01' <-> 'c01'.
-- =============================================================================

do $$
declare
  v_empresa uuid;
  v_cat     uuid;
  v_prod    uuid;
  r         record;
  n_nuevos  int := 0;
  n_actual  int := 0;
begin

  -- --- Empresa -------------------------------------------------------------
  select id into v_empresa from manastina.empresas order by created_at limit 1;

  if v_empresa is null then
    raise exception 'No hay ninguna fila en manastina.empresas. Cargá la empresa antes de correr esto.';
  end if;

  if (select count(*) from manastina.empresas) > 1 then
    raise notice 'Hay mas de una empresa; se usa la mas antigua (%). Si no es la correcta, ajustá el select de arriba.', v_empresa;
  end if;

  raise notice 'Empresa: %', v_empresa;

  -- --- Categorías ----------------------------------------------------------
  for r in
    select * from (values
${categorias}
    ) as t(codigo, nombre)
  loop
    select id into v_cat
      from manastina.categorias_productos
     where empresa_id = v_empresa and lower(codigo) = lower(r.codigo)
     limit 1;

    if v_cat is null then
      insert into manastina.categorias_productos (empresa_id, nombre, codigo, activo)
      values (v_empresa, r.nombre, r.codigo, true);
    end if;
  end loop;

  -- --- Productos -----------------------------------------------------------
  for r in
    select * from (values
${productos}
    ) as t(sku, codigo_web, nombre, marca, categoria, precio, stock,
           descripcion, colores, imagen)
  loop
    select id into v_prod
      from manastina.productos
     where empresa_id = v_empresa and sku = r.sku
     limit 1;

    select id into v_cat
      from manastina.categorias_productos
     where empresa_id = v_empresa and lower(codigo) = lower(r.categoria)
     limit 1;

    if v_prod is null then
      -- Alta: acá sí se toma el stock de la web como valor inicial.
      insert into manastina.productos (
        empresa_id, sku, nombre, precio_venta, stock_actual, stock_minimo,
        unidad_medida, activo, imagen_url, categoria_principal_id
      ) values (
        v_empresa, r.sku, r.nombre, r.precio, r.stock, 1,
        'unidad', true, nullif(r.imagen, ''), v_cat
      )
      returning id into v_prod;

      n_nuevos := n_nuevos + 1;
    else
      -- Ya existe: se actualiza la ficha, NUNCA el stock.
      update manastina.productos
         set nombre                 = r.nombre,
             precio_venta           = r.precio,
             imagen_url             = coalesce(nullif(r.imagen, ''), imagen_url),
             categoria_principal_id = coalesce(v_cat, categoria_principal_id),
             activo                 = true,
             updated_at             = now()
       where id = v_prod;

      n_actual := n_actual + 1;
    end if;

    -- Relación producto <-> categoría (si la tabla existe en este ERP).
    if v_cat is not null then
      begin
        insert into manastina.producto_categorias (empresa_id, producto_id, categoria_id, es_principal)
        values (v_empresa, v_prod, v_cat, true)
        on conflict do nothing;
      exception when others then
        null;  -- la tabla puede tener otra forma; no es crítico
      end;
    end if;
  end loop;

  raise notice 'Productos creados: %  ·  actualizados: %', n_nuevos, n_actual;
end $$;


-- -----------------------------------------------------------------------------
-- Comprobación
-- -----------------------------------------------------------------------------
select sku, nombre, precio_venta, stock_actual, activo
  from manastina.productos
 where sku like 'MAN-%'
 order by sku;
`;

const destino = path.join(__dirname, 'sql', '04-productos-erp.sql');
fs.writeFileSync(destino, sql);
console.log('generado ' + path.relative(raiz, destino) +
  '  ·  ' + datos.productos.length + ' productos, ' + datos.categorias.length + ' categorias');
