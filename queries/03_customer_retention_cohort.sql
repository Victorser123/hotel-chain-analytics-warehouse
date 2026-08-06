/*
================================================================
CUSTOMER RETENTION BY PROPERTY
================================================================
AUTHOR: Victor Sernaque

BUSINESS QUESTION:
  What share of each property's customers from one year returned
  the next? Which properties keep guests, and which keep replacing them?

USE CASE:
  Retention is the cheapest growth lever in this business — a returning
  guest costs nothing to acquire. This query tells the commercial team
  where a loyalty programme would pay for itself and where the problem
  is acquisition, not retention.

TECHNIQUE — FLAG BY ENTITY-PERIOD:
  The CTE reduces the fact table to one row per (customer, property)
  carrying a 0/1 flag per year. Every cohort then becomes a
  combination of those flags, counted with SUM(CASE WHEN ...).

  The obvious alternative — three CTEs combined with EXCEPT and
  INTERSECT — was the first implementation and was replaced: it ran
  three correlated existence checks per fact row, and each additional
  year meant another CTE. The flag pattern scales by adding one
  MAX(CASE WHEN) column.

RETENTION DENOMINATOR:
  Retained customers over *all* customers active in the base year —
  not over total customers. A customer who first appeared in the
  later year was never at risk of churning and does not belong in
  the denominator.

GRAIN NOTE:
  Grouping by (customer, property) means retention is measured
  per property. A guest who switches from one property to another
  counts as churn for the first and acquisition for the second,
  which is the correct read when each property owns its own P&L.
================================================================
*/

WITH cliente_hotel_flags AS (
    SELECT
        r.cliente_id,
        r.hotel_id,
        MAX(CASE WHEN df.anio = 2024 THEN 1 ELSE 0 END) AS compro_base,
        MAX(CASE WHEN df.anio = 2025 THEN 1 ELSE 0 END) AS compro_siguiente
    FROM reservas r
    JOIN dim_fecha df ON df.fecha = r.fecha_checkin
    WHERE df.anio IN (2024, 2025)
      AND NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
    GROUP BY r.cliente_id, r.hotel_id
)
SELECT
    h.nombre AS hotel,

    SUM(CASE WHEN compro_base = 1 AND compro_siguiente = 0 THEN 1 ELSE 0 END)
        AS clientes_perdidos,
    SUM(CASE WHEN compro_base = 0 AND compro_siguiente = 1 THEN 1 ELSE 0 END)
        AS clientes_nuevos,
    SUM(CASE WHEN compro_base = 1 AND compro_siguiente = 1 THEN 1 ELSE 0 END)
        AS clientes_retenidos,

    SUM(CASE WHEN compro_base = 1 THEN 1 ELSE 0 END) AS base_year_total,

    ROUND(
        100.0 * SUM(CASE WHEN compro_base = 1 AND compro_siguiente = 1 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN compro_base = 1 THEN 1 ELSE 0 END), 0),
        2
    ) AS pct_retencion,

    -- Net customer movement: positive means the property grew its
    -- base, negative means acquisition is not covering churn
    SUM(CASE WHEN compro_base = 0 AND compro_siguiente = 1 THEN 1 ELSE 0 END)
    - SUM(CASE WHEN compro_base = 1 AND compro_siguiente = 0 THEN 1 ELSE 0 END)
        AS movimiento_neto

FROM cliente_hotel_flags chf
JOIN hoteles h ON h.hotel_id = chf.hotel_id
GROUP BY h.nombre
ORDER BY pct_retencion DESC NULLS LAST;
