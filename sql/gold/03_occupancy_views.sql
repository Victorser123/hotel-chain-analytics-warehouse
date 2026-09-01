/*
================================================================================
 GOLD — OCCUPANCY VIEWS
================================================================================
 Layer: Gold (reporting)

 TWO MEASUREMENT FRAMES — WHY BOTH EXIST
   Hospitality reporting runs on two clocks:
     OCCUPANCY  → attributed to the night of stay (these views)
     PRODUCTION → attributed to the date the booking was sold
   A booking made in January for a July stay counts toward January production
   and July occupancy. Conflating the two was the single biggest source of
   disagreement in the legacy spreadsheet reports, so they live in separate
   files and never mix.

 SHARED BUSINESS RULE
   Bookings both unpaid and still in 'Reservado' are unconfirmed holds and are
   excluded from every view below.

 ROOM TYPE FILTERING
   Non-lodging SKUs are excluded via dim_tipo_habitacion.categoria, not a
   hardcoded NOT IN list. Before the dimension existed the same 15-item list was
   duplicated across every view; adding one SKU meant editing all of them.
================================================================================
*/

CREATE OR REPLACE VIEW v_ocupabilidad_total AS 
SELECT 
    h.nombre                             AS hotel,
    rd.año                               AS anio,
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
GROUP BY h.nombre, rd.año, rd.mes;


CREATE OR REPLACE VIEW v_ventas_ocupabilidad_reservas AS 
SELECT 
    h.nombre                             AS hotel,
    rd.año                               AS anio,
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
  AND dth.categoria = 'Habitacion'
GROUP BY h.nombre, rd.año, rd.mes;


CREATE OR REPLACE VIEW v_ventas_con_carpa_total AS 
SELECT 
    h.nombre                             AS hotel,
    rd.año                               AS anio,
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
GROUP BY h.nombre, rd.año, rd.mes;



-- ============================================================
-- PAID vs PARTNER REVENUE SPLIT
-- ============================================================
/*
  Splits each hotel-month between paying guests and VIP partner redemptions.
  Partner stays consume inventory but generate little or no cash, so a hotel can
  look full while under-performing on revenue.

  THREE FIXES APPLIED TO THE WORKING COPY

  1. The join to reservas_detalle carried only id_reserva_origen. With
     annually recycled booking IDs that cross-multiplies each booking against
     the detail rows of its namesakes in other years and inflates both the
     count and the revenue. Now joins on the full composite key.

  2. NULLIF sat on the numerator of every percentage:
       nullif(sum(...) FILTER (...), 0) / sum(rd.total) * 100
     which guards nothing — the denominator was still unprotected and a
     hotel-month with no qualifying rows raised a division by zero and broke
     the whole report. Moved to the denominator.

  3. The integer percentages truncated: count(...)*100/count(...) is integer
     division, so 66.7% rendered as 66. Now computed in numeric and rounded.

  Also removed a hardcoded `WHERE rd.mes = 6 AND rd.año = 2026` that pinned the
  view to a single month. The period columns are in the output; the caller
  filters.
*/


create or replace view v_ocupabilidad_pago_socios as
SELECT r.hotel_id, rd.mes, rd.año,
 count(rd.id_reserva_origen) as total_reservas,
 sum(rd.total) as total_ingresos,
 count(rd.id_reserva_origen) FILTER (WHERE dc.area_trabajo <> 'Socios') as total_reservas_pago,
 round(count(rd.id_reserva_origen) FILTER (WHERE dc.area_trabajo <> 'Socios')*100.0
       / nullif(count(rd.id_reserva_origen),0), 2) as percentage_res_pago,
 sum(rd.total)FILTER (WHERE dc.area_trabajo <> 'Socios') as total_ingresos_pago,
 round(sum(rd.total) FILTER (WHERE dc.area_trabajo <> 'Socios')*100.0
       / nullif(sum(rd.total),0), 2) as percentage_ing_pago,
 count(rd.id_reserva_origen) FILTER (WHERE dc.area_trabajo = 'Socios') as total_reservas_socios,
 round(count(rd.id_reserva_origen) FILTER (WHERE dc.area_trabajo = 'Socios')*100.0
       / nullif(count(rd.id_reserva_origen),0), 2) as percentage_res_socios,
 sum(rd.total)FILTER (WHERE dc.area_trabajo = 'Socios') as total_ingresos_socios,
 round(sum(rd.total) FILTER (WHERE dc.area_trabajo = 'Socios')*100.0
       / nullif(sum(rd.total),0), 2) as percentage_ing_socios
from reservas r
join reservas_detalle rd on r.id_reserva_origen = rd.id_reserva_origen
                        and r.anio_creacion     = rd.anio_creacion
join dim_canal dc on r.canal = dc.nombre_canal
join dim_tipo_habitacion dth on rd.tipo_habitacion = dth.nombre_tipo
where NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
  AND dth.categoria = 'Habitacion'
group by r.hotel_id,rd.mes, rd.año
