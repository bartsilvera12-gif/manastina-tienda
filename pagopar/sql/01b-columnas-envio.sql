-- =============================================================================
-- MANASTINA · Columnas que se sumaron después de la primera versión
-- =============================================================================
-- Correr solo si ya ejecutaste 01-tablas-web.sql antes de que existieran las
-- tarifas de envío por ciudad. Es idempotente: si las columnas ya están, no
-- hace nada.
--
-- Si vas a crear las tablas desde cero, 01-tablas-web.sql ya las incluye y
-- este archivo no hace falta.
-- =============================================================================

-- Zona con la que se identifica el pedido ante PagoPar. Su catálogo agrupa el
-- país en pocas zonas: sirve para su registro, no para calcular el envío.
alter table manastina.web_pedidos
  add column if not exists ciudad_hub_pagopar text;

-- Tarifa de delivery de esa ciudad, se haya cobrado online o quede para el
-- momento de la entrega. null = fuera de la zona, se acuerda por WhatsApp.
alter table manastina.web_pedidos
  add column if not exists envio_estimado bigint;

-- true = el envío NO se cobró online; lo paga el cliente al recibirlo.
alter table manastina.web_pedidos
  add column if not exists envio_aparte boolean not null default false;

comment on column manastina.web_pedidos.ciudad_codigo is
  'Ciudad real de reparto (clave interna, ej. "capiata"). Es la que manda para el envío y para el ERP.';

comment on column manastina.web_pedidos.envio_estimado is
  'Tarifa de delivery de la ciudad. null = fuera de la zona de reparto, a coordinar.';

comment on column manastina.web_pedidos.envio_aparte is
  'true = queda plata por cobrar al entregar (el envío no entró en el pago online).';
