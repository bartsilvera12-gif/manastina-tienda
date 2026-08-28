-- =============================================================================
-- MANASTINA · Habilitar los módulos nuevos en el menú del ERP
-- =============================================================================
-- Los módulos del ERP salen en el menú solo si están habilitados para la
-- empresa. Las migraciones los habilitan solas, pero si alguna corrió antes de
-- que existiera la tienda, o si el usuario no es administrador, el módulo queda
-- creado y sin aparecer.
--
-- Esto lo arregla para Marcas, Colecciones y Pedidos web. Es idempotente: se
-- puede correr las veces que haga falta.
--
-- Toca SOLO el schema `manastina`.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Primero, el diagnóstico
-- -----------------------------------------------------------------------------
-- Si algo de la primera fila sale en `false`, falta correr la migración del ERP
-- (20260827210000_marcas.sql) antes que esto.
select
  to_regclass('manastina.marcas')          is not null                     as tabla_marcas,
  exists (
    select 1 from information_schema.columns
     where table_schema = 'manastina'
       and table_name   = 'productos'
       and column_name  = 'marca_id'
  )                                                                        as columna_marca_id,
  to_regclass('manastina.colecciones_web') is not null                     as tabla_colecciones,
  to_regclass('manastina.v_web_catalogo')  is not null                     as vista_catalogo;

-- Qué módulos existen y en cuántas empresas están prendidos.
select m.slug,
       m.nombre,
       count(em.*) filter (where em.activo) as empresas_habilitadas
  from manastina.modulos m
  left join manastina.empresa_modulos em on em.modulo_id = m.id
 where m.slug in ('marcas', 'colecciones', 'pedidos-web', 'inventario')
 group by m.slug, m.nombre
 order by m.slug;


-- -----------------------------------------------------------------------------
-- Ahora, el arreglo
-- -----------------------------------------------------------------------------
do $$
declare
  s        text;
  v_modulo uuid;
  v_inv    uuid;
  v_nombre text;
  v_desc   text;
begin
  select id into v_inv from manastina.modulos where slug = 'inventario' limit 1;

  foreach s in array array['marcas', 'colecciones', 'pedidos-web']
  loop
    v_nombre := case s
                  when 'marcas'      then 'Marcas'
                  when 'colecciones' then 'Colecciones'
                  else                    'Pedidos web'
                end;
    v_desc   := case s
                  when 'marcas'      then 'Marcas de producto, con su logo para la tienda online'
                  when 'colecciones' then 'Colecciones de la portada de la tienda online'
                  else                    'Pedidos de la tienda online: que despachar y a donde'
                end;

    -- 1) Que el módulo exista en el catálogo.
    select id into v_modulo from manastina.modulos where slug = s limit 1;
    if v_modulo is null then
      insert into manastina.modulos (nombre, descripcion, slug)
      values (v_nombre, v_desc, s)
      returning id into v_modulo;
      raise notice '[modulos] % creado', s;
    end if;

    -- 2) Que esté prendido para todas las empresas del schema.
    insert into manastina.empresa_modulos (empresa_id, modulo_id, activo)
    select e.id, v_modulo, true
      from manastina.empresas e
     where not exists (
       select 1 from manastina.empresa_modulos em
        where em.empresa_id = e.id and em.modulo_id = v_modulo
     );

    update manastina.empresa_modulos
       set activo = true
     where modulo_id = v_modulo
       and activo is distinct from true;

    -- 3) Los usuarios que no son administradores ven solo lo que tienen
    --    asignado. A los que ya ven Inventario se les suma este módulo: si
    --    manejan el stock, también manejan esto.
    if v_inv is not null and to_regclass('manastina.usuario_modulos') is not null then
      insert into manastina.usuario_modulos (usuario_id, modulo_id)
      select um.usuario_id, v_modulo
        from manastina.usuario_modulos um
       where um.modulo_id = v_inv
         and not exists (
           select 1 from manastina.usuario_modulos u2
            where u2.usuario_id = um.usuario_id and u2.modulo_id = v_modulo
         );
    end if;

    raise notice '[modulos] % habilitado', s;
  end loop;
end;
$$;


-- -----------------------------------------------------------------------------
-- Comprobación
-- -----------------------------------------------------------------------------
-- Los tres tienen que salir con al menos una empresa habilitada.
select m.slug,
       count(em.*) filter (where em.activo) as empresas_habilitadas
  from manastina.modulos m
  left join manastina.empresa_modulos em on em.modulo_id = m.id
 where m.slug in ('marcas', 'colecciones', 'pedidos-web')
 group by m.slug
 order by m.slug;
