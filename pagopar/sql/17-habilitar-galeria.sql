-- =============================================================================
-- MANASTINA · Habilitar el módulo Galería en el menú del ERP
-- =============================================================================
-- El módulo sale en el menú solo si está prendido para la empresa, y la
-- migración lo prende solo donde encuentra la tabla `galeria_web`. Si se corrió
-- antes que el script 16, el módulo queda sin habilitar.
--
-- Esto lo arregla. Y si la tabla todavía no está, lo dice en vez de dejar el
-- módulo prendido apuntando a la nada.
--
-- Es idempotente y toca SOLO el schema `manastina`.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Diagnóstico
-- -----------------------------------------------------------------------------
select
  to_regclass('manastina.galeria_web')   is not null                   as tabla_galeria,
  to_regclass('manastina.v_web_galeria') is not null                   as vista_galeria,
  coalesce((select count(*) from manastina.modulos where slug = 'galeria'), 0)
                                                                       as modulo_en_catalogo;


-- -----------------------------------------------------------------------------
-- Arreglo
-- -----------------------------------------------------------------------------
do $$
declare
  v_modulo uuid;
  v_inv    uuid;
begin
  if to_regclass('manastina.galeria_web') is null then
    raise notice '';
    raise notice '  FALTA CORRER EL 16-galeria-portada.sql PRIMERO.';
    raise notice '  Sin la tabla galeria_web el modulo no tiene de donde sacar nada,';
    raise notice '  asi que no se habilita. Corre ese script y despues este.';
    raise notice '';
    return;
  end if;

  select id into v_modulo from manastina.modulos where slug = 'galeria' limit 1;
  if v_modulo is null then
    insert into manastina.modulos (nombre, descripcion, slug)
    values ('Galeria', 'Fotos y videos de la galeria de la tienda online', 'galeria')
    returning id into v_modulo;
    raise notice '[galeria] modulo creado';
  end if;

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

  -- Los usuarios que no son administradores ven solo lo que tienen asignado.
  -- A los que ya ven Inventario se les suma este modulo.
  select id into v_inv from manastina.modulos where slug = 'inventario' limit 1;
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

  raise notice '[galeria] habilitado';
end;
$$;


-- -----------------------------------------------------------------------------
-- Comprobación
-- -----------------------------------------------------------------------------
select m.slug,
       count(em.*) filter (where em.activo) as empresas_habilitadas,
       (select count(*) from manastina.galeria_web) as piezas_cargadas
  from manastina.modulos m
  left join manastina.empresa_modulos em on em.modulo_id = m.id
 where m.slug = 'galeria'
 group by m.slug;
