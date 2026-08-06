/*
================================================================
DATA QUALITY & PIPELINE MONITORING
================================================================
AUTHOR: Victor Sernaque
LAYER:  Governance

PURPOSE:
  Automated health checks run against the warehouse after every load.
  Each check returns a count plus a traffic-light status, so a single
  SELECT answers "is today's data trustworthy?".

DESIGN:
  Checks are UNION ALL'd into one result set rather than split into
  separate views, so the whole suite can be pinned to a dashboard as
  a single query and any regression is visible at a glance.

SEVERITY MODEL:
  Thresholds are per-check, not global. Orphaned records are CRITICAL
  at any count because they mean referential integrity broke. Missing
  hotel cities are only a warning — a new property simply has not been
  enriched yet.
================================================================
*/

-- ============================================================
-- WAREHOUSE HEALTH CHECK — 10 automated validations
-- ============================================================
CREATE OR REPLACE VIEW v_health_check AS

-- 1. Bookings pointing at a customer that does not exist
SELECT
    'Reservas huérfanas (cliente_id inválido)' AS chequeo,
    COUNT(*)                                   AS conteo,
    CASE WHEN COUNT(*) = 0       THEN 'OK'
         WHEN COUNT(*) <= 10     THEN 'ATENCIÓN'
         ELSE                         'CRÍTICO' END AS estado
FROM reservas r
WHERE NOT EXISTS (SELECT 1 FROM clientes c WHERE c.cliente_id = r.cliente_id)

UNION ALL

-- 2. Detail rows with no parent booking — always critical, it means
--    the composite FK was bypassed or the load ran out of order
SELECT
    'Detalles huérfanos (sin reserva)',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'CRÍTICO' END
FROM reservas_detalle rd
WHERE NOT EXISTS (
    SELECT 1 FROM reservas r
    WHERE r.id_reserva_origen = rd.id_reserva_origen
      AND r.anio_creacion     = rd.anio_creacion
)

UNION ALL

-- 3. Negative amounts — a handful are legitimate refunds, more than
--    that suggests a sign error somewhere upstream
SELECT
    'Detalles con precio negativo',
    COUNT(*),
    CASE WHEN COUNT(*) = 0   THEN 'OK'
         WHEN COUNT(*) <= 5  THEN 'ATENCIÓN'
         ELSE                     'CRÍTICO' END
FROM reservas_detalle
WHERE precio < 0 OR total < 0

UNION ALL

-- 4. Duplicate national IDs — would silently split one customer's
--    history across two records and break all retention metrics
SELECT
    'DNIs duplicados en clientes',
    COUNT(*) - COUNT(DISTINCT dni),
    CASE WHEN COUNT(*) - COUNT(DISTINCT dni) = 0 THEN 'OK'
         ELSE 'CRÍTICO' END
FROM clientes

UNION ALL

-- 5. Hotel dimension not yet enriched
SELECT
    'Hoteles sin ciudad',
    COUNT(*),
    CASE WHEN COUNT(*) = 0   THEN 'OK'
         WHEN COUNT(*) <= 2  THEN 'ATENCIÓN'
         ELSE                     'CRÍTICO' END
FROM hoteles
WHERE ciudad IS NULL

UNION ALL

-- 6. New channels appearing in source without an owning team —
--    their revenue would fall out of every team-filtered report
SELECT
    'Canales sin clasificar',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'ATENCIÓN' END
FROM dim_canal
WHERE area_trabajo = 'Sin clasificar'

UNION ALL

-- 7. Bookings referencing a property that is not in the dimension
SELECT
    'Reservas con hotel inexistente',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'CRÍTICO' END
FROM reservas r
WHERE NOT EXISTS (SELECT 1 FROM hoteles h WHERE h.hotel_id = r.hotel_id)

UNION ALL

-- 8. Load freshness — catches the silent failure mode where the
--    scheduler stops and nobody notices because the data still looks fine
SELECT
    'Última carga completada',
    1,
    CASE
        WHEN NOT EXISTS (SELECT 1 FROM etl_log WHERE proceso = 'refresh_silver')
            THEN 'NUNCA EJECUTADA'
        WHEN (SELECT estado FROM etl_log
              WHERE proceso = 'refresh_silver'
              ORDER BY fecha_inicio DESC LIMIT 1) = 'ERROR'
            THEN 'ERROR EN ÚLTIMA'
        WHEN (SELECT fecha_inicio FROM etl_log
              WHERE proceso = 'refresh_silver'
              ORDER BY fecha_inicio DESC LIMIT 1) < NOW() - INTERVAL '2 days'
            THEN 'HACE MÁS DE 2 DÍAS'
        ELSE 'OK'
    END

UNION ALL

-- 9. Outlier amounts — usually a decimal-place error or a currency
--    conversion applied twice
SELECT
    'Reservas con total > 150k soles (revisar)',
    COUNT(*),
    CASE WHEN COUNT(*) = 0   THEN 'OK'
         WHEN COUNT(*) <= 3  THEN 'ATENCIÓN'
         ELSE                     'CRÍTICO' END
FROM reservas
WHERE total_reserva > 150000

UNION ALL

-- 10. Logically impossible stay dates
SELECT
    'Reservas con checkout < checkin (imposible)',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'CRÍTICO' END
FROM reservas
WHERE fecha_checkout < fecha_checkin;


-- ============================================================
-- RECENT PIPELINE ACTIVITY
-- ============================================================
-- First place to look when a report shows unexpected numbers:
-- did the load run, and did it finish clean?
CREATE OR REPLACE VIEW v_carga_reciente AS
SELECT
    log_id,
    proceso,
    accion,
    filas_afectadas,
    estado,
    ROUND(duracion_segundos, 2)                       AS segundos,
    TO_CHAR(fecha_inicio, 'DD/MM/YYYY HH24:MI:SS')    AS inicio,
    mensaje
FROM etl_log
ORDER BY fecha_inicio DESC
LIMIT 50;


-- ============================================================
-- PIPELINE RELIABILITY — ROLLING 30 DAYS
-- ============================================================
-- Success rate and duration trend per process. A creeping average
-- duration is the early warning that a step is about to time out.
CREATE OR REPLACE VIEW v_carga_stats AS
SELECT
    proceso,
    COUNT(*)                                  AS total_ejecuciones,
    COUNT(*) FILTER (WHERE estado = 'OK')     AS exitosas,
    COUNT(*) FILTER (WHERE estado = 'ERROR')  AS fallidas,
    ROUND(AVG(duracion_segundos)::NUMERIC, 2) AS duracion_promedio_seg,
    ROUND(MAX(duracion_segundos)::NUMERIC, 2) AS duracion_maxima_seg,
    MAX(fecha_inicio)                         AS ultima_ejecucion
FROM etl_log
WHERE fecha_inicio >= NOW() - INTERVAL '30 days'
GROUP BY proceso;
