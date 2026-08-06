/*
================================================================
MULTI-YEAR REVENUE COMPARISON (2022–2026)
================================================================
AUTHOR: Victor Sernaque

BUSINESS QUESTION:
  How does each property's performance in a given month compare
  against the same month across the pryors years?

USE CASE:
  Board reporting and budget defence. Seasonality in this chain is
  pronounced, so a month-over-month number is meaningless.

TECHNIQUE:
  One conditional aggregate per year via FILTER (WHERE), producing
  a wide row per property. The year-over-year percentage compares the
  two most recent years and is NULLIF-guarded, because properties
  that opened mid-series have a zero prior-year base.

MEASUREMENT FRAME:
  Stay date (rd.fecha), not booking date — this is a revenue
  realisation view, not a sales attribution view.

PARAMETER:
  The target month is hardcoded below. In production this runs from
  the BI layer with the month passed as a parameter.
================================================================
*/

SELECT
    h.nombre AS hotel,

    ROUND(SUM(rd.total) FILTER (WHERE rd."año" = 2022), 2) AS ingresos_2022,
    COUNT(*)            FILTER (WHERE rd."año" = 2022)     AS noches_2022,

    ROUND(SUM(rd.total) FILTER (WHERE rd."año" = 2023), 2) AS ingresos_2023,
    COUNT(*)            FILTER (WHERE rd."año" = 2023)     AS noches_2023,

    ROUND(SUM(rd.total) FILTER (WHERE rd."año" = 2024), 2) AS ingresos_2024,
    COUNT(*)            FILTER (WHERE rd."año" = 2024)     AS noches_2024,

    ROUND(SUM(rd.total) FILTER (WHERE rd."año" = 2025), 2) AS ingresos_2025,
    COUNT(*)            FILTER (WHERE rd."año" = 2025)     AS noches_2025,

    ROUND(SUM(rd.total) FILTER (WHERE rd."año" = 2026), 2) AS ingresos_2026,
    COUNT(*)            FILTER (WHERE rd."año" = 2026)     AS noches_2026,

    -- Latest year vs prior year. NULL when the property had no
    -- prior-year activity, which is the honest answer for a
    -- property that opened mid-series.
    ROUND(
        100.0 * (
            SUM(rd.total) FILTER (WHERE rd."año" = 2026)
            - SUM(rd.total) FILTER (WHERE rd."año" = 2025)
        ) / NULLIF(SUM(rd.total) FILTER (WHERE rd."año" = 2025), 0),
        2
    ) AS crecimiento_yoy_pct

FROM reservas r
JOIN reservas_detalle rd
    ON r.id_reserva_origen = rd.id_reserva_origen
   AND r.anio_creacion     = rd.anio_creacion
JOIN hoteles h
    ON h.hotel_id = r.hotel_id
JOIN dim_tipo_habitacion dth
    ON dth.nombre_tipo = rd.tipo_habitacion
WHERE rd."año" >= 2022
  AND rd.mes = 6                    -- target month
  AND dth.categoria = 'Habitacion'
  AND NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
GROUP BY h.nombre
ORDER BY ingresos_2026 DESC NULLS LAST;
