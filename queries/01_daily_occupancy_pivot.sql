/*
================================================================
DAILY OCCUPANCY — PIVOTED BY PROPERTY
================================================================
AUTHOR: Victor Sernaque

BUSINESS QUESTION:
  What is today's occupancy rate and revenue at each property,
  side by side, for the current month?

USE CASE:
  Daily operations stand-up. One row per date, one column block per
  property — the shape managers already read in their spreadsheets,
  so adoption required no retraining.

WHY PIVOTED:
  The long-format version (one row per hotel per day) is the correct
  relational shape but forces the reader to scan 7 rows to compare
  properties on a given date. FILTER (WHERE) collapses it to one row
  per date, making cross-property comparison a horizontal read.

  Trade-off accepted deliberately: adding a property means adding a
  column block. At 7 properties that is manageable; at 50 the long
  format plus a BI-layer pivot would be the right call.

OCCUPANCY DENOMINATOR:
  hoteles.cantidad_hab is the room inventory. MAX() is used inside
  the FILTER because the value is constant per hotel — it is an
  aggregate-safe way to carry a dimension attribute through a
  GROUP BY without adding it to the grouping key.

EXCLUSIONS:
  Three internal IDs are excluded: they are non-operating entities
  rather than properties open to guests.
================================================================
*/

SELECT
    rd.fecha,

    -- Property 41
    SUM(rd.total)                    FILTER (WHERE r.hotel_id = 41) AS h41_ingresos,
    COUNT(*)                         FILTER (WHERE r.hotel_id = 41) AS h41_ocupadas,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE r.hotel_id = 41)
        / NULLIF(MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 41), 0), 2
    ) AS h41_pct_ocupacion,

    -- Property 60
    SUM(rd.total)                    FILTER (WHERE r.hotel_id = 60) AS h60_ingresos,
    COUNT(*)                         FILTER (WHERE r.hotel_id = 60) AS h60_ocupadas,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE r.hotel_id = 60)
        / NULLIF(MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 60), 0), 2
    ) AS h60_pct_ocupacion,

    -- Property 61
    SUM(rd.total)                    FILTER (WHERE r.hotel_id = 61) AS h61_ingresos,
    COUNT(*)                         FILTER (WHERE r.hotel_id = 61) AS h61_ocupadas,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE r.hotel_id = 61)
        / NULLIF(MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 61), 0), 2
    ) AS h61_pct_ocupacion,

    -- Property 64
    SUM(rd.total)                    FILTER (WHERE r.hotel_id = 64) AS h64_ingresos,
    COUNT(*)                         FILTER (WHERE r.hotel_id = 64) AS h64_ocupadas,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE r.hotel_id = 64)
        / NULLIF(MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 64), 0), 2
    ) AS h64_pct_ocupacion,

    -- Property 69
    SUM(rd.total)                    FILTER (WHERE r.hotel_id = 69) AS h69_ingresos,
    COUNT(*)                         FILTER (WHERE r.hotel_id = 69) AS h69_ocupadas,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE r.hotel_id = 69)
        / NULLIF(MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 69), 0), 2
    ) AS h69_pct_ocupacion,

    -- Property 71
    SUM(rd.total)                    FILTER (WHERE r.hotel_id = 71) AS h71_ingresos,
    COUNT(*)                         FILTER (WHERE r.hotel_id = 71) AS h71_ocupadas,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE r.hotel_id = 71)
        / NULLIF(MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 71), 0), 2
    ) AS h71_pct_ocupacion,

    -- Property 86
    SUM(rd.total)                    FILTER (WHERE r.hotel_id = 86) AS h86_ingresos,
    COUNT(*)                         FILTER (WHERE r.hotel_id = 86) AS h86_ocupadas,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE r.hotel_id = 86)
        / NULLIF(MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 86), 0), 2
    ) AS h86_pct_ocupacion

FROM reservas r
JOIN reservas_detalle rd
    ON r.id_reserva_origen = rd.id_reserva_origen
   AND r.anio_creacion     = rd.anio_creacion
JOIN hoteles h
    ON r.hotel_id = h.hotel_id
JOIN dim_tipo_habitacion dth
    ON dth.nombre_tipo = rd.tipo_habitacion
WHERE r.hotel_id NOT IN (29, 999, 66)
  AND dth.categoria = 'Habitacion'
  AND NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
  AND rd.fecha >= DATE_TRUNC('month', CURRENT_DATE)
  AND rd.fecha <  DATE_TRUNC('month', CURRENT_DATE) + INTERVAL '1 month'
GROUP BY rd.fecha
ORDER BY rd.fecha;
