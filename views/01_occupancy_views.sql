/*
================================================================
OCCUPANCY VIEWS — hotel-chain
================================================================
AUTHOR: Victor Sernaque
LAYER:  Gold (reporting)

TWO MEASUREMENT FRAMES — WHY BOTH EXIST:
  Hospitality reporting needs two different clocks:
    - OCCUPANCY  → attributed to the night of stay (these views)
    - PRODUCTION → attributed to the date the booking was created
  A booking made in January for a July stay counts toward January
  production and July occupancy. Conflating the two was the single
  biggest source of disagreement in the legacy spreadsheet reports.

SHARED BUSINESS RULE:
  Bookings that are both unpaid and still in 'Reservado' status are
  unconfirmed holds and are excluded from every view below.

ROOM TYPE FILTERING:
  Non-lodging SKUs (event boxes, entrance tickets, zones) are excluded
  via dim_tipo_habitacion.categoria rather than a hardcoded NOT IN list.
  Before this dimension existed the same 15-item list was duplicated
  across every view; adding one SKU meant editing all of them.
================================================================
*/

-- ============================================================
-- ROOMS ONLY — the headline occupancy number
-- ============================================================
CREATE OR REPLACE VIEW v_ocupabilidad_total AS
SELECT
    h.nombre                             AS hotel,
    rd."año"                             AS anio,
    rd.mes                               AS mes,
    SUM(rd.total)                        AS total_ingresos,
    COUNT(DISTINCT rd.id_reserva_origen) AS cantidad_reservas
FROM reservas_detalle rd
JOIN reservas r
    ON rd.id_reserva_origen = r.id_reserva_origen
   AND rd.anio_creacion     = r.anio_creacion
JOIN hoteles h
    ON r.hotel_id = h.hotel_id
JOIN dim_tipo_habitacion dth
    ON dth.nombre_tipo = rd.tipo_habitacion
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
  AND dth.categoria = 'Habitacion'
GROUP BY h.nombre, rd."año", rd.mes;


-- ============================================================
-- ROOMS ONLY, RESERVATIONS TEAM ONLY
-- ============================================================
-- Isolates revenue the central reservations team is accountable for,
-- excluding walk-ins and partner bookings the team did not source.
CREATE OR REPLACE VIEW v_ventas_ocupabilidad_reservas AS
SELECT
    h.nombre                             AS hotel,
    rd."año"                             AS anio,
    rd.mes                               AS mes,
    SUM(rd.total)                        AS total_ingresos,
    COUNT(DISTINCT rd.id_reserva_origen) AS cantidad_reservas
FROM reservas_detalle rd
JOIN reservas r
    ON rd.id_reserva_origen = r.id_reserva_origen
   AND rd.anio_creacion     = r.anio_creacion
JOIN hoteles h
    ON r.hotel_id = h.hotel_id
JOIN dim_canal dc
    ON r.canal = dc.nombre_canal
JOIN dim_tipo_habitacion dth
    ON dth.nombre_tipo = rd.tipo_habitacion
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
  AND dc.area_trabajo = 'Área Reservas'
  AND dth.categoria   = 'Habitacion'
GROUP BY h.nombre, rd."año", rd.mes;


-- ============================================================
-- PAID vs PARTNER REVENUE SPLIT
-- ============================================================
/*
  Splits each hotel-month between paying guests and VIP partner
  redemptions. Partner stays consume inventory but generate little
  or no cash, so a hotel can look full while under-performing on
  revenue. This view surfaces that gap in a single row.

  NULLIF guards every ratio: hotels with zero qualifying rows in a
  month would otherwise raise a division-by-zero and break the
  whole report.
*/
CREATE OR REPLACE VIEW v_ocupabilidad_pago_socios AS
SELECT
    r.hotel_id,
    rd."año" AS anio,
    rd.mes,

    COUNT(rd.id_reserva_origen) AS total_reservas,
    SUM(rd.total)               AS total_ingresos,

    -- Paying guests
    COUNT(rd.id_reserva_origen) FILTER (WHERE dc.area_trabajo <> 'Socios')
        AS total_reservas_pago,
    ROUND(
        100.0 * COUNT(rd.id_reserva_origen) FILTER (WHERE dc.area_trabajo <> 'Socios')
        / NULLIF(COUNT(rd.id_reserva_origen), 0), 2
    ) AS pct_reservas_pago,
    SUM(rd.total) FILTER (WHERE dc.area_trabajo <> 'Socios')
        AS total_ingresos_pago,
    ROUND(
        100.0 * SUM(rd.total) FILTER (WHERE dc.area_trabajo <> 'Socios')
        / NULLIF(SUM(rd.total), 0), 2
    ) AS pct_ingresos_pago,

    -- VIP partner redemptions
    COUNT(rd.id_reserva_origen) FILTER (WHERE dc.area_trabajo = 'Socios')
        AS total_reservas_socios,
    ROUND(
        100.0 * COUNT(rd.id_reserva_origen) FILTER (WHERE dc.area_trabajo = 'Socios')
        / NULLIF(COUNT(rd.id_reserva_origen), 0), 2
    ) AS pct_reservas_socios,
    SUM(rd.total) FILTER (WHERE dc.area_trabajo = 'Socios')
        AS total_ingresos_socios,
    ROUND(
        100.0 * SUM(rd.total) FILTER (WHERE dc.area_trabajo = 'Socios')
        / NULLIF(SUM(rd.total), 0), 2
    ) AS pct_ingresos_socios

FROM reservas r
JOIN reservas_detalle rd
    ON r.id_reserva_origen = rd.id_reserva_origen
   AND r.anio_creacion     = rd.anio_creacion
JOIN dim_canal dc
    ON r.canal = dc.nombre_canal
JOIN dim_tipo_habitacion dth
    ON rd.tipo_habitacion = dth.nombre_tipo
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
  AND dth.categoria = 'Habitacion'
GROUP BY r.hotel_id, rd."año", rd.mes;
