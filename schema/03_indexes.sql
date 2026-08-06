/*
================================================================================
 SCHEMA — INDEXES
================================================================================
 Purpose:  Indexes supporting the join and filter paths exercised by the
           reporting layer and the ETL.
 Run:      After 02_core_tables.sql.

 SELECTION RATIONALE
 -------------------
 Indexes were added for columns that appear in JOIN conditions or WHERE filters
 across the reporting views — not indiscriminately. Low-cardinality boolean
 flags and columns only appearing in SELECT lists were deliberately skipped:
 they would slow down the full-refresh ETL without improving read paths.

 The two Bronze indexes matter because the incremental DELETE has to parse a
 text-typed date column on every load.
================================================================================
*/

-- ── Silver: reservations ─────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_reservas_hotel     ON reservas(hotel_id);
CREATE INDEX IF NOT EXISTS idx_reservas_cliente   ON reservas(cliente_id);
CREATE INDEX IF NOT EXISTS idx_reservas_creacion  ON reservas(fecha_creacion);
CREATE INDEX IF NOT EXISTS idx_reservas_canal     ON reservas(canal);
CREATE INDEX IF NOT EXISTS idx_reservas_checkin   ON reservas(fecha_checkin);

-- ── Silver: reservation detail ───────────────────────────────────────────────
-- The composite index mirrors the composite FK, so joins from header to detail
-- resolve via index rather than a sequential scan of 130k rows.
CREATE INDEX IF NOT EXISTS idx_detalle_fecha      ON reservas_detalle(fecha);
CREATE INDEX IF NOT EXISTS idx_detalle_reserva    ON reservas_detalle(id_reserva_origen, anio_creacion);

-- ── Bronze: raw landing zone ─────────────────────────────────────────────────
-- Dates arrive as text in DD/MM/YYYY, and the incremental delete filters on
-- TO_DATE("FECHA", ...). A plain index on the text column is not usable for
-- that predicate — the index has to be built on the same expression the
-- planner sees. to_date() is IMMUTABLE, which is what makes this legal.
CREATE INDEX IF NOT EXISTS idx_bronze_fecha
    ON bronze_reservas_raw ((TO_DATE("FECHA", 'DD/MM/YYYY')));

CREATE INDEX IF NOT EXISTS idx_bronze_fecha_creac
    ON bronze_reservas_raw ((TO_DATE("FECHA_CREACION", 'DD/MM/YYYY')));
