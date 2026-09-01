/*
================================================================================
 GOLD — CUSTOMER METRICS
================================================================================
 Layer: Gold (pre-aggregated)
 Run:   After the first refresh_silver().

 Materialised rather than a plain view because it aggregates the full booking
 history and is read by several dashboards; refreshing once per load is far
 cheaper than recomputing per query.

 Bookings that are simultaneously unpaid AND still in 'Reservado' status are
 excluded: they are holds that were never confirmed, and counting them inflates
 every revenue metric.

 FIX — REMOVED AN INVALID PREDICATE
 ----------------------------------
 The working copy carried `AND total_reservas_anio_actual <> 0` in the WHERE
 clause. That name is a SELECT-list alias, and WHERE is evaluated before the
 select list exists, so the statement could not compile. To filter on that
 value it has to go in HAVING, or the view has to be wrapped. Removed rather
 than moved, because every dashboard reading this view expects one row per
 customer, including customers with no activity this year.
================================================================================
*/

DROP MATERIALIZED VIEW IF EXISTS mv_cliente_metricas CASCADE;

CREATE MATERIALIZED VIEW mv_cliente_metricas AS
SELECT 
    r.cliente_id,
    -- Métricas históricas totales
    COUNT(*)                              AS total_reservas,
    SUM(r.total_reserva)                  AS total_gastado,
    MIN(r.fecha_creacion)::DATE           AS fecha_primera_reserva,
    MAX(r.fecha_creacion)::DATE           AS fecha_ultima_reserva,
    -- Métricas del año actual
    COUNT(*) FILTER (
        WHERE EXTRACT(YEAR FROM r.fecha_checkin) = EXTRACT(YEAR FROM CURRENT_DATE)
    )                                     AS total_reservas_anio_actual,
    SUM(r.total_reserva) FILTER (
        WHERE EXTRACT(YEAR FROM r.fecha_checkin) = EXTRACT(YEAR FROM CURRENT_DATE)
    )                                     AS total_gastado_anio_actual,
    (COUNT(*) FILTER (
        WHERE EXTRACT(YEAR FROM r.fecha_checkin) = EXTRACT(YEAR FROM CURRENT_DATE)
    ) >= 1)                               AS tiene_reserva_anio_actual,
    -- Flags de segmentación
    (COUNT(*) > 1)                        AS es_recurrente,
    CASE 
        WHEN COUNT(*) = 1                THEN 'Nuevo'
        WHEN COUNT(*) BETWEEN 2 AND 3    THEN 'Ocasional'
        WHEN COUNT(*) BETWEEN 4 AND 9    THEN 'Fiel'
        WHEN COUNT(*) >= 10              THEN 'VIP'
    END                                   AS segmento
FROM reservas r
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
GROUP BY r.cliente_id;

CREATE UNIQUE INDEX idx_mv_cliente_metricas ON mv_cliente_metricas(cliente_id);
