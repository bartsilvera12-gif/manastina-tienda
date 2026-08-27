-- =============================================================================
-- MANASTINA · Marca de consulta a PagoPar
-- =============================================================================
-- La pagina de retorno le pregunta a PagoPar como quedo el pedido. Esa consulta
-- se hace una sola vez por pedido, y esta columna es la que lo recuerda.
--
-- Ademas de evitar preguntas de mas, sirve para el circuito de certificacion de
-- PagoPar, que exige ver al menos una consulta de estado del comercio.
-- =============================================================================

alter table manastina.web_pedidos
  add column if not exists consultado_at timestamptz;

comment on column manastina.web_pedidos.consultado_at is
  'Cuando se le pregunto a PagoPar por este pedido. Se hace una sola vez.';

notify pgrst, 'reload schema';
