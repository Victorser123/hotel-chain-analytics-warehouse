/*
================================================================================
 SILVER — INDEXES
================================================================================
 Run: After 01_core_tables.sql.

 SELECTION RATIONALE
 -------------------
 Added for columns that appear in JOIN conditions or WHERE filters across the
 reporting views, not indiscriminately. Low-cardinality boolean flags and
 columns that only appear in SELECT lists were deliberately skipped: they would
 slow the full-refresh ETL without improving any read path.

 idx_detalle_reserva mirrors the composite foreign key, so header-to-detail
 joins resolve by index instead of scanning the detail table.

 Bronze indexes live in sql/bronze/02_indexes.sql, next to the table they
 belong to.
================================================================================
*/

CREATE INDEX IF NOT EXISTS idx_reservas_hotel      ON reservas(hotel_id);
CREATE INDEX IF NOT EXISTS idx_reservas_cliente    ON reservas(cliente_id);
CREATE INDEX IF NOT EXISTS idx_reservas_creacion   ON reservas(fecha_creacion);
CREATE INDEX IF NOT EXISTS idx_reservas_canal      ON reservas(canal);
CREATE INDEX IF NOT EXISTS idx_reservas_checkin    ON reservas(fecha_checkin);
CREATE INDEX IF NOT EXISTS idx_detalle_fecha       ON reservas_detalle(fecha);
CREATE INDEX IF NOT EXISTS idx_detalle_reserva     ON reservas_detalle(id_reserva_origen, anio_creacion);

