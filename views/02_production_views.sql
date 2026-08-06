/*
================================================================
PRODUCTION VIEWS — hotel-chain
================================================================
AUTHOR: Victor Sernaque
LAYER:  Gold (reporting)

MEASUREMENT FRAME:
  Everything here is attributed to fecha_creacion — the date the
  booking was sold, not the date the guest stays. This is the frame
  used to evaluate the sales team: an agent is credited the day they
  close the sale, regardless of when the stay happens.

  See 01_occupancy_views.sql for the complementary stay-date frame.

SHARED BUSINESS RULE:
  Unpaid bookings still sitting in 'Reservado' status are unconfirmed
  holds and are excluded from every view below.
================================================================
*/

-- ============================================================
-- PRODUCTION BY HOTEL AND MONTH
-- ============================================================
-- Restricted to channels owned by the reservations team, so the
-- number is directly comparable against that team's targets.
CREATE OR REPLACE VIEW v_produccion AS
SELECT
    h.nombre                                  AS hotel,
    EXTRACT(YEAR  FROM r.fecha_creacion)::INT AS anio_creacion,
    EXTRACT(MONTH FROM r.fecha_creacion)::INT AS mes_creacion,
    SUM(r.total_reserva)                      AS total_ingresos,
    COUNT(*)                                  AS cantidad_reservas
FROM reservas r
JOIN hoteles h    ON r.hotel_id = h.hotel_id
JOIN dim_canal dc ON r.canal    = dc.nombre_canal
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
  AND dc.area_trabajo = 'Área Reservas'
GROUP BY h.nombre,
         EXTRACT(YEAR  FROM r.fecha_creacion),
         EXTRACT(MONTH FROM r.fecha_creacion);


-- ============================================================
-- AGENT RANKING WITH TARGET ATTAINMENT
-- ============================================================
/*
  Joins actual production against monthly targets at agent-month grain.

  LEFT JOIN on the target table, not INNER: agents without a target
  loaded for a given month must still appear with their actuals, or
  the ranking silently drops people and the totals stop reconciling.

  Joined on id_usuario_origen rather than the agent's name — the
  source system exports the same person under several accent-corrupted
  spellings, which would fragment a name-based join.
*/
CREATE OR REPLACE VIEW v_ranking_asesores AS
SELECT
    da.asesor_id,
    da.nombre_asesor,
    da.area_trabajo,
    EXTRACT(YEAR  FROM r.fecha_creacion)::INT AS anio,
    EXTRACT(MONTH FROM r.fecha_creacion)::INT AS mes,
    SUM(r.total_reserva)                      AS total_ingresos,
    COUNT(*)                                  AS cantidad_reservas,
    ma.meta_produccion,
    ROUND(
        100.0 * SUM(r.total_reserva) / NULLIF(ma.meta_produccion, 0),
        2
    ) AS pct_cumplimiento
FROM reservas r
JOIN dim_asesor da
    ON da.id_usuario_origen = r.id_usuario_asesor
LEFT JOIN metas_asesor_mes ma
    ON ma.asesor_id = da.asesor_id
   AND ma.anio      = EXTRACT(YEAR  FROM r.fecha_creacion)::INT
   AND ma.mes       = EXTRACT(MONTH FROM r.fecha_creacion)::INT
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
GROUP BY
    da.asesor_id, da.nombre_asesor, da.area_trabajo,
    EXTRACT(YEAR  FROM r.fecha_creacion),
    EXTRACT(MONTH FROM r.fecha_creacion),
    ma.meta_produccion;


-- ============================================================
-- AGENT PRODUCTION AT DAILY GRAIN
-- ============================================================
/*
  Daily detail behind v_ranking_asesores, used for intra-month pacing:
  it answers "is this agent on track with 10 days left?" rather than
  "did they hit target last month?".

  The `llave` column concatenates agent + YYYYMM into a single key so
  the BI layer can relate this view to the monthly target table with a
  one-column relationship instead of a composite join, which Power BI
  does not support natively.
*/
CREATE OR REPLACE VIEW v_produccion_asesor AS
SELECT
    r.asesor_reserva,
    da.asesor_id,
    DATE(r.fecha_creacion)                          AS fecha,
    EXTRACT(YEAR  FROM DATE(r.fecha_creacion))::INT AS anio,
    EXTRACT(MONTH FROM DATE(r.fecha_creacion))::INT AS mes,
    EXTRACT(DAY   FROM DATE(r.fecha_creacion))::INT AS dia,
    SUM(rd.total)                                   AS cant_ing_prod,
    COUNT(rd.id_reserva_origen)                     AS cant_res_prod,
    CONCAT(
        da.asesor_id, '-',
        EXTRACT(YEAR FROM DATE(r.fecha_creacion))::INT,
        LPAD(EXTRACT(MONTH FROM DATE(r.fecha_creacion))::TEXT, 2, '0')
    ) AS llave
FROM reservas r
JOIN reservas_detalle rd
    ON r.id_reserva_origen = rd.id_reserva_origen
   AND r.anio_creacion     = rd.anio_creacion
JOIN dim_canal dc
    ON r.canal = dc.nombre_canal
JOIN dim_asesor da
    ON da.id_usuario_origen = r.id_usuario_asesor
WHERE dc.area_trabajo = 'Área Reservas'
  AND NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
GROUP BY r.asesor_reserva, da.asesor_id, DATE(r.fecha_creacion);


-- ============================================================
-- AGENT CONTRIBUTION BY HOTEL
-- ============================================================
-- Cross-tabs agents against properties: reveals whether an agent's
-- volume comes from one property or is spread across the chain,
-- which changes how their result should be read.
CREATE OR REPLACE VIEW v_ocupacion_asesor_hotel AS
SELECT
    da.asesor_id,
    da.nombre_asesor,
    h.hotel_id,
    h.nombre         AS hotel,
    rd."año"         AS anio,
    rd.mes,
    SUM(rd.total)    AS total_ingresos,
    SUM(rd.cantidad) AS cantidad_noches
FROM reservas_detalle rd
JOIN reservas r
    ON rd.id_reserva_origen = r.id_reserva_origen
   AND rd.anio_creacion     = r.anio_creacion
JOIN hoteles h
    ON r.hotel_id = h.hotel_id
JOIN dim_canal dc
    ON r.canal = dc.nombre_canal
JOIN dim_asesor da
    ON da.id_usuario_origen = r.id_usuario_asesor
JOIN dim_tipo_habitacion dth
    ON dth.nombre_tipo = rd.tipo_habitacion
WHERE dc.area_trabajo = 'Área Reservas'
  AND dth.categoria   = 'Habitacion'
  AND NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
GROUP BY da.asesor_id, da.nombre_asesor, h.hotel_id, h.nombre, rd."año", rd.mes;
