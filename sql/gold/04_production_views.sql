/*
================================================================================
 GOLD — PRODUCTION VIEWS
================================================================================
 Layer: Gold (reporting)

 MEASUREMENT FRAME
   Everything here is attributed to fecha_creacion — the date the booking was
   sold, not the date the guest stays. This is the frame used to evaluate the
   sales team: an agent is credited the day they close the sale, regardless of
   when the stay happens.

   See 03_occupancy_views.sql for the complementary stay-date frame.

 JOIN KEY
   Agents join on dim_asesor.id_usuario_origen, never on the name. The source
   exports the same person under several accent-corrupted spellings, and a
   name-based join fragments one person into several rows and understates their
   performance.

 SHARED BUSINESS RULE
   Unpaid bookings still in 'Reservado' are unconfirmed holds and are excluded.
================================================================================
*/

CREATE OR REPLACE VIEW v_produccion AS
SELECT 
    h.nombre                                          AS hotel,
    EXTRACT(YEAR  FROM r.fecha_creacion)::INT         AS anio_creacion,
    EXTRACT(MONTH FROM r.fecha_creacion)::INT         AS mes_creacion,
    SUM(r.total_reserva)                              AS total_ingresos,
    COUNT(*)                                          AS cantidad_reservas
FROM reservas r
JOIN hoteles h ON r.hotel_id = h.hotel_id
JOIN dim_canal dc ON r.canal = dc.nombre_canal
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
  AND dc.area_trabajo = 'Área Reservas'
GROUP BY h.nombre, 
         EXTRACT(YEAR FROM r.fecha_creacion),
         EXTRACT(MONTH FROM r.fecha_creacion);



-- ============================================================
-- AGENT RANKING WITH TARGET ATTAINMENT
-- ============================================================
/*
  Joins actual production against monthly targets at agent-month grain.

  LEFT JOIN on the target table, not INNER: an agent with no target loaded for
  a month must still appear with their actuals, or the ranking silently drops
  people and the totals stop reconciling.
*/


CREATE OR REPLACE VIEW v_ranking_asesores AS
SELECT 
    da.asesor_id,
    da.nombre_asesor,
    da.area_trabajo,
    EXTRACT(YEAR  FROM r.fecha_creacion)::INT     AS anio,
    EXTRACT(MONTH FROM r.fecha_creacion)::INT     AS mes,
    SUM(r.total_reserva)                          AS total_ingresos,
    COUNT(*)                                      AS cantidad_reservas,
    ma.meta_produccion,
    ROUND(
        (SUM(r.total_reserva) / NULLIF(ma.meta_produccion, 0)) * 100, 
        2
    )                                             AS pct_cumplimiento
FROM reservas r
JOIN dim_asesor da 
    ON da.id_usuario_origen = r.id_usuario_asesor
LEFT JOIN metas_asesor_mes ma 
    ON ma.asesor_id = da.asesor_id
    AND ma.anio = EXTRACT(YEAR  FROM r.fecha_creacion)::INT
    AND ma.mes  = EXTRACT(MONTH FROM r.fecha_creacion)::INT
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
GROUP BY 
    da.asesor_id, da.nombre_asesor, da.area_trabajo,
    EXTRACT(YEAR FROM r.fecha_creacion),
    EXTRACT(MONTH FROM r.fecha_creacion),
    ma.meta_produccion;



-- ============================================================
-- AGENT PRODUCTION AT DAILY GRAIN
-- ============================================================
/*
  Daily detail behind v_ranking_asesores, used for intra-month pacing: it
  answers "is this agent on track with 10 days left?" rather than "did they hit
  target last month?".

  The `llave` column concatenates agent + YYYYMM into one key so the BI layer
  can relate this view to the monthly target table with a single-column
  relationship, which is what Power BI supports natively.

  FIX: the join to reservas_detalle carried only id_reserva_origen. Recycled
  booking IDs made it cross-multiply across years, inflating every agent's
  production. Now joins on the full composite key.
*/


create or replace view v_produccion_asesor as
    Select r.asesor_reserva, da.asesor_id ,
    DATE(r.fecha_creacion) AS fecha,
    EXTRACT(YEAR FROM DATE(r.fecha_creacion))::int AS anio,
    EXTRACT(MONTH FROM DATE(r.fecha_creacion))::int AS mes,
    EXTRACT(DAY FROM DATE(r.fecha_creacion))::int AS dia,
    sum(rd.total) cant_ing_prod, count(rd.id_reserva_origen) as cant_res_prod, 
    CONCAT(
    da.asesor_id,
    '-',
    EXTRACT(YEAR FROM DATE(r.fecha_creacion))::int,
    LPAD(EXTRACT(MONTH FROM DATE(r.fecha_creacion))::text, 2, '0')
    ) AS llave
    from reservas r 
    join reservas_detalle rd on r.id_reserva_origen = rd.id_reserva_origen
                            and r.anio_creacion     = rd.anio_creacion
    join dim_canal dc on r.canal = dc.nombre_canal
    JOIN dim_asesor da ON da.id_usuario_origen = r.id_usuario_asesor
    where dc.area_trabajo = 'Área Reservas'
    GROUP BY
    r.asesor_reserva,
    da.asesor_id,
    DATE(r.fecha_creacion)
    order by anio desc, mes  desc, dia desc;



-- ============================================================
-- AGENT CONTRIBUTION BY HOTEL
-- ============================================================
/*
  Cross-tabs agents against properties: reveals whether an agent's volume comes
  from one property or is spread across the chain, which changes how their
  result should be read.

  FIX: the 14-item hardcoded room-type exclusion array is replaced by the
  dim_tipo_habitacion category filter used by every other view. It was the last
  copy of the list this dimension exists to eliminate, and it was already out
  of sync — it omitted '~CARPAS', so tent revenue leaked into this view and
  into no other.
*/


CREATE OR REPLACE VIEW v_ocupacion_asesor_hotel AS
SELECT
    r.id_usuario_asesor           AS asesor_id,
    r.asesor_reserva,
    h.hotel_id,
    h.nombre                      AS hotel,
    rd.mes,
    rd.año                       AS anio,
    SUM(rd.total)                 AS total_ingresos,
    SUM(rd.cantidad)              AS cantidad_noches
FROM reservas_detalle rd
JOIN reservas r
  ON rd.id_reserva_origen = r.id_reserva_origen
 AND rd.anio_creacion     = r.anio_creacion
JOIN hoteles h
  ON r.hotel_id = h.hotel_id
join dim_canal dc
on r.canal = dc.nombre_canal
join dim_tipo_habitacion dth
on rd.tipo_habitacion = dth.nombre_tipo
where dc.area_trabajo = 'Área Reservas'
and NOT (r.estado_pago::text = 'No pagado'::text
       AND r.estado_reserva::text = 'Reservado'::text)
  AND dth.categoria = 'Habitacion'
GROUP BY r.id_usuario_asesor, r.asesor_reserva, h.hotel_id, h.nombre, rd.mes, rd."año";
