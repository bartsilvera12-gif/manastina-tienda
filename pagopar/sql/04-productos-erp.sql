-- =============================================================================
-- MANASTINA · Catálogo de la web dentro del ERP
-- =============================================================================
-- GENERADO AUTOMÁTICAMENTE — no editar a mano.
-- Se regenera con:  node pagopar/generar-sql-productos.js
--
-- Carga los 25 productos reales de la tienda en manastina.productos,
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
    ('carteras', 'Carteras'),
    ('bandoleras', 'Bandoleras'),
    ('accesorios', 'Billeteras y accesorios'),
    ('sets', 'Sets')
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
    ('MAN-C01', 'c01', 'Set Chrisbella con documentera', 'Chrisbella', 'sets', 295000, 5, 'Set combinado de dos piezas a juego, en tono camel.', 'Camel', 'assets/catalogo/set-chrisbella-con-documentera-1.jpeg'),
    ('MAN-C02', 'c02', 'Set Chrisbella con neceser y porta tablet', 'Chrisbella', 'sets', 315000, 5, 'Set de tres piezas con neceser y porta tablet, para el día completo.', 'Negro', 'assets/catalogo/set-chrisbella-con-neceser-y-porta-tablet-1.jpeg'),
    ('MAN-C03', 'c03', 'Set Chrisbella negro con documentera', 'Chrisbella', 'sets', 295000, 5, 'Set combinado de dos piezas a juego, en negro.', 'Negro', 'assets/catalogo/set-chrisbella-negro-con-documentera-1.jpeg'),
    ('MAN-C04', 'c04', 'Bandolera David Jones', 'David Jones', 'bandoleras', 240000, 5, 'Bandolera compacta con correa regulable y cierre superior.', 'Negro', 'assets/catalogo/bandolera-david-jones-1.jpeg'),
    ('MAN-C05', 'c05', 'Cartera David Jones', 'David Jones', 'carteras', 250000, 5, 'Cartera estructurada con herrajes dorados y manijas en contraste.', 'Taupe', 'assets/catalogo/cartera-david-jones-1.jpeg'),
    ('MAN-C06', 'c06', 'Cartera David Jones Paris', 'David Jones', 'carteras', 250000, 5, 'Cartera de mano con textura símil croco y base firme.', 'Rojo', 'assets/catalogo/cartera-david-jones-paris-1.jpeg'),
    ('MAN-C07', 'c07', 'Cartera tote David Jones Paris', 'David Jones', 'carteras', 240000, 5, 'Tote amplio de uso diario, con pañuelo decorativo.', 'Negro', 'assets/catalogo/cartera-tote-david-jones-paris-1.jpeg'),
    ('MAN-C08', 'c08', 'Billetera larga Guess negro', 'Guess', 'accesorios', 280000, 5, 'Billetera larga con múltiples espacios para tarjetas y cierre con broche.', 'Negro', 'assets/catalogo/billetera-larga-guess-negro-1.jpeg'),
    ('MAN-C09', 'c09', 'Billetera larga Guess', 'Guess', 'accesorios', 280000, 5, 'Billetera larga con logo metálico y amplia capacidad de tarjetas.', 'Borgoña / Beige', 'assets/catalogo/billetera-larga-guess-1.jpeg'),
    ('MAN-C10', 'c10', 'Claudia Satchel Guess', 'Guess', 'carteras', 620000, 5, 'Satchel estructurado con estampa de logo y correa desmontable.', 'Gris logo', 'assets/catalogo/claudia-satchel-guess-1.jpeg'),
    ('MAN-C11', 'c11', 'Lacy Satchel Guess', 'Guess', 'carteras', 630000, 5, 'Satchel de doble compartimento con herrajes dorados.', 'Beige logo', 'assets/catalogo/lacy-satchel-guess-1.jpeg'),
    ('MAN-C12', 'c12', 'Billetera larga Nine West', 'Nine West', 'accesorios', 290000, 5, 'Billetera larga con organizador interior y cierre perimetral.', 'Negro', 'assets/catalogo/billetera-larga-nine-west-1.jpeg'),
    ('MAN-C13', 'c13', 'Crossbody Bownie Nine West', 'Nine West', 'bandoleras', 370000, 5, 'Bandolera formato cámara, con bolsillo frontal y correa regulable.', 'Negro', 'assets/catalogo/crossbody-bownie-nine-west-1.jpeg'),
    ('MAN-C14', 'c14', 'Crossbody Emberly Nine West', 'Nine West', 'bandoleras', 370000, 5, 'Bandolera matelaseada con cadena metálica desmontable.', 'Negro', 'assets/catalogo/crossbody-emberly-nine-west-1.jpeg'),
    ('MAN-C15', 'c15', 'Tote Nine West', 'Nine West', 'carteras', 550000, 5, 'Tote de líneas limpias y gran capacidad, para el uso diario.', 'Negro', 'assets/catalogo/tote-nine-west-1.jpeg'),
    ('MAN-C16', 'c16', 'Bandolera mini Flight Prune', 'Prune', 'bandoleras', 490000, 5, 'Bandolera mini de nylon técnico, liviana y resistente.', 'Negro', 'assets/catalogo/bandolera-mini-flight-prune-1.jpeg'),
    ('MAN-C17', 'c17', 'Bandolera Rubber Prune negro', 'Prune', 'bandoleras', 390000, 5, 'Bandolera de uso urbano con correa ancha y detalles en goma.', 'Negro', 'assets/catalogo/bandolera-rubber-prune-negro-1.jpeg'),
    ('MAN-C18', 'c18', 'Cartera al hombro Flight Prune de nylon', 'Prune', 'carteras', 550000, 5, 'Cartera al hombro en nylon, liviana y de formato amplio.', 'Negro', 'assets/catalogo/cartera-al-hombro-flight-prune-de-nylon-1.jpeg'),
    ('MAN-C19', 'c19', 'Shopper Erin Prune efecto cuero marrón', 'Prune', 'carteras', 590000, 5, 'Shopper de gran capacidad en efecto cuero, con asas al hombro.', 'Marrón', 'assets/catalogo/shopper-erin-prune-efecto-cuero-marron-1.jpeg'),
    ('MAN-C20', 'c20', 'Cartera Rosa Amora', 'Rosa Amora', 'carteras', 280000, 5, 'Cartera con manija trenzada y monedero a juego.', 'Cognac', 'assets/catalogo/cartera-rosa-amora-1.jpeg'),
    ('MAN-C21', 'c21', 'Cartera Rosa Amora marrón', 'Rosa Amora', 'carteras', 280000, 5, 'Cartera estructurada con manija trenzada y monedero a juego.', 'Marrón', 'assets/catalogo/cartera-rosa-amora-marron-1.jpeg'),
    ('MAN-C22', 'c22', 'Cartera Rosa Amora negro', 'Rosa Amora', 'carteras', 280000, 5, 'Cartera con textura trenzada, cadena y monedero a juego.', 'Negro', 'assets/catalogo/cartera-rosa-amora-negro-1.jpeg'),
    ('MAN-C23', 'c23', 'Carterita Rosa Amora', 'Rosa Amora', 'carteras', 270000, 5, 'Carterita con cadena metálica, correa de cuero y monedero a juego.', 'Cognac', 'assets/catalogo/carterita-rosa-amora-1.jpeg'),
    ('MAN-C24', 'c24', 'Billetera Timberland', 'Timberland', 'accesorios', 295000, 5, 'Billetera con porta documento y espacios para tarjetas.', 'Negro', 'assets/catalogo/billetera-timberland-1.jpeg'),
    ('MAN-C25', 'c25', 'Morral Timberland', 'Timberland', 'bandoleras', 250000, 5, 'Morral compacto de nylon, con bolsillo frontal y correa regulable.', 'Negro', 'assets/catalogo/morral-timberland-1.jpeg')
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
