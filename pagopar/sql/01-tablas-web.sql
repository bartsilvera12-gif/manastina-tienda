-- =============================================================================
-- MANASTINA · Tienda web — tablas para el cobro con PagoPar
-- =============================================================================
-- Correr una sola vez en: Supabase -> SQL Editor.
--
-- NO toca ninguna tabla del ERP. Crea dos tablas nuevas con prefijo `web_`
-- dentro del schema `manastina` que ya existe.
--
-- La columna `venta_id` queda vacía a propósito: es el punto de enganche para
-- cuando el ERP quiera convertir un pedido web pagado en una venta real.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Pedidos de la tienda web
-- -----------------------------------------------------------------------------
create table if not exists manastina.web_pedidos (
  id                    uuid primary key default gen_random_uuid(),

  -- Número entero que se le manda a PagoPar como `id_pedido_comercio`.
  -- Es el mismo valor que entra en el token SHA1, por eso es único.
  id_pedido_comercio    bigint not null unique,

  -- Empresa del ERP a la que pertenece la tienda. Se llena desde la config.
  empresa_id            uuid,

  -- --- Datos del comprador (los que exige PagoPar) ---
  cliente_nombre        text not null,
  cliente_email         text not null,
  cliente_telefono      text not null,
  cliente_documento     text not null,

  -- Ciudad: código de hub PagoPar (1-15) + el nombre para mostrar.
  ciudad_codigo         text not null,
  ciudad_nombre         text,

  direccion             text default '',
  direccion_referencia  text default '',

  -- 'envio' | 'retiro'
  modalidad             text not null default 'envio',
  observaciones         text default '',

  -- --- Montos en guaraníes, siempre enteros ---
  subtotal              bigint not null,
  envio                 bigint not null default 0,
  total                 bigint not null,

  -- --- Estado del cobro ---
  -- 'pendiente' | 'pagado' | 'rechazado' | 'vencido'
  estado_pago           text not null default 'pendiente',
  pagopar_hash          text unique,
  pagopar_link          text,
  pagopar_forma_pago    text,
  pagopar_respuesta     jsonb,
  pagado_at             timestamptz,

  -- --- Enganche futuro con el ERP (lo llena el ERP, no la web) ---
  venta_id              uuid,
  cliente_id            uuid,

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  constraint web_pedidos_estado_valido
    check (estado_pago in ('pendiente','pagado','rechazado','vencido')),
  constraint web_pedidos_modalidad_valida
    check (modalidad in ('envio','retiro')),
  constraint web_pedidos_total_positivo
    check (total > 0)
);

comment on table manastina.web_pedidos is
  'Pedidos de la tienda web manastina.com cobrados con PagoPar. Independiente del ERP; venta_id engancha con manastina.ventas cuando el ERP lo procese.';


-- -----------------------------------------------------------------------------
-- Líneas del pedido
-- -----------------------------------------------------------------------------
create table if not exists manastina.web_pedido_items (
  id                uuid primary key default gen_random_uuid(),
  pedido_id         uuid not null
                      references manastina.web_pedidos(id) on delete cascade,

  -- Código del catálogo de la web (c01, c02, ...). No es el uuid del ERP.
  producto_codigo   text not null,

  -- Enganche futuro con manastina.productos. Vacío por ahora.
  producto_id       uuid,

  nombre            text not null,
  color             text default '',
  cantidad          integer not null,
  precio_unitario   bigint not null,
  total_linea       bigint not null,

  created_at        timestamptz not null default now(),

  constraint web_pedido_items_cantidad_positiva check (cantidad > 0)
);

comment on table manastina.web_pedido_items is
  'Lineas de cada pedido web. producto_codigo es el id del catalogo estatico; producto_id queda para enganchar con manastina.productos.';


-- -----------------------------------------------------------------------------
-- Índices
-- -----------------------------------------------------------------------------
create index if not exists web_pedidos_estado_idx
  on manastina.web_pedidos (estado_pago, created_at desc);

create index if not exists web_pedidos_hash_idx
  on manastina.web_pedidos (pagopar_hash)
  where pagopar_hash is not null;

create index if not exists web_pedidos_email_idx
  on manastina.web_pedidos (lower(cliente_email));

create index if not exists web_pedido_items_pedido_idx
  on manastina.web_pedido_items (pedido_id);


-- -----------------------------------------------------------------------------
-- updated_at automático
-- -----------------------------------------------------------------------------
create or replace function manastina.web_pedidos_touch()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists web_pedidos_touch_trg on manastina.web_pedidos;
create trigger web_pedidos_touch_trg
  before update on manastina.web_pedidos
  for each row execute function manastina.web_pedidos_touch();


-- -----------------------------------------------------------------------------
-- Seguridad: RLS prendido y SIN políticas.
-- -----------------------------------------------------------------------------
-- Con RLS activo y cero políticas, `anon` y `authenticated` no ven ni escriben
-- nada. Solo la `service_role` (que usan las Edge Functions) pasa de largo.
-- El navegador nunca toca estas tablas directamente.
--
-- Si después el ERP necesita leerlas desde el panel con un usuario logueado,
-- se agrega una política ahí; no hace falta ahora.
-- -----------------------------------------------------------------------------
alter table manastina.web_pedidos      enable row level security;
alter table manastina.web_pedido_items enable row level security;

revoke all on manastina.web_pedidos      from anon, authenticated;
revoke all on manastina.web_pedido_items from anon, authenticated;
