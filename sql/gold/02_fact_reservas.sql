/*
================================================================================
 GOLD — FLAT FACT VIEW FOR THE BI LAYER
================================================================================
 Layer: Gold
 Run:   After the first refresh_silver().

 One wide row per room-night with the header, hotel and customer attributes
 already joined, so Power BI consumes a single object instead of resolving a
 composite-key star at query time.

 GRAIN WARNING — READ BEFORE AGGREGATING
 ---------------------------------------
 The grain is the room-night, not the booking. Header columns — noches_total
 and total_reserva above all — are repeated on every night of the stay. SUM()
 over either of them multiplies revenue by the length of stay. Use rd.total for
 anything summed at this grain; use the reservas table directly for
 booking-level totals.

 The join carries both key columns, which is what keeps a recycled booking ID
 from cross-multiplying against its namesakes in other years.

 CONTAINS PII
 ------------
 dni, cliente and telefono are personally identifying. This view is deliberately
 NOT granted to authenticated in sql/ops/grants_rls.sql; it is for the BI
 service account only.
================================================================================
*/

CREATE MATERIALIZED VIEW fact_reservas AS
SELECT
    r.id_reserva_origen,
    r.anio_creacion,
    r.hotel_id,
    h.nombre                AS hotel,
    r.cliente_id,
    c.dni,
    c.nombre                AS cliente,
    c.telefono,
    r.canal,
    r.sub_canal,
    r.asesor_reserva,
    r.estado_reserva,
    r.estado_pago,
    r.moneda,
    r.fecha_creacion,
    EXTRACT(MONTH FROM r.fecha_creacion)::INT AS mes_creacion,
    r.noches_total,
    r.total_reserva,
    rd.fecha,
    EXTRACT(YEAR  FROM rd.fecha)::INT AS anio_estadia,
    EXTRACT(MONTH FROM rd.fecha)::INT AS mes_estadia,
    rd.habitacion_numero,
    rd.tipo_habitacion,
    rd.cantidad,
    rd.precio,
    rd.total,
    rd.pax_adultos,
    rd.pax_ninos
FROM reservas r
JOIN hoteles h           ON h.hotel_id   = r.hotel_id
JOIN clientes c          ON c.cliente_id = r.cliente_id
JOIN reservas_detalle rd 
  ON rd.id_reserva_origen = r.id_reserva_origen
 AND rd.anio_creacion     = r.anio_creacion;

CREATE INDEX idx_fact_fecha     ON fact_reservas(fecha);
CREATE INDEX idx_fact_hotel     ON fact_reservas(hotel);
CREATE INDEX idx_fact_asesor    ON fact_reservas(asesor_reserva);
CREATE INDEX idx_fact_canal     ON fact_reservas(canal);
