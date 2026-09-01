/*
================================================================================
 BRONZE — RAW LANDING ZONE
================================================================================
 Layer: Bronze
 Run:   First. Everything downstream reads from this table.

 RECONSTRUCTED DDL — VERIFY BEFORE USE
 -------------------------------------
 The landing table is created by the Excel loader, not by a migration, so no
 CREATE statement for it exists in the project history. The column list below
 is reconstructed from every reference in refresh_silver() and the dimension
 loads; the types are inferred from how each column is consumed:

   - FECHA, FECHA_CREACION and HORA_CREACION are TEXT, because the pipeline
     casts them with TO_DATE(..., 'DD/MM/YYYY') and ::TIME
   - IDRESERVA, IDHOTEL, NUMERO, CANT, ESTADO, PAXA, PAXN are integer, because
     they are inserted into integer columns with no cast
   - IDUSUARIO is BIGINT, compared with > 0
   - PRECIO and TOTAL are numeric, multiplied by the exchange rate directly

 Confirm against the live database with:

   SELECT column_name, data_type, ordinal_position
   FROM information_schema.columns
   WHERE table_name = 'bronze_reservas_raw'
   ORDER BY ordinal_position;

 WHY DATES ARE TEXT AND THE REST IS NOT
 --------------------------------------
 The source is an Excel export from an untyped legacy PMS whose dates arrive as
 DD/MM/YYYY strings. Keeping them as text makes the landing table a faithful
 mirror and defers the cast to one place — refresh_silver() — instead of making
 the loader reject a whole batch over a single unparseable cell.
================================================================================
*/

CREATE TABLE IF NOT EXISTS bronze_reservas_raw (
    -- Booking identity. IDRESERVA is recycled annually by the source and is
    -- NOT unique on its own; see the composite key in sql/silver.
    "IDRESERVA"         INT,
    "IDHOTEL"           INT,
    "FECHA_CREACION"    TEXT,   -- DD/MM/YYYY, booking sale date
    "HORA_CREACION"     TEXT,   -- HH24:MI:SS

    -- Customer
    "DNI"               TEXT,
    "NOMBRE"            TEXT,
    "TELEFONO_CELULAR"  TEXT,

    -- Commercial attribution
    "DESCRIPCION"       TEXT,   -- sales channel
    "SUB CANAL"         TEXT,   -- the source header really does contain a space
    "ASESOR_RESERVA"    TEXT,   -- agent name, accent-corrupted in the source
    "IDUSUARIO"         BIGINT, -- agent ID: the stable key, always join on this

    -- Booking status
    "ESTADO"            INT,
    "ESTADORESERVA"     TEXT,
    "ESTADOPAGO"        TEXT,
    "MONEDA"            TEXT,

    -- Stay line. Grain: one room, one night.
    "FECHA"             TEXT,   -- DD/MM/YYYY, night of stay
    "NUMERO"            INT,    -- room number
    "DESCRIPCION1"      TEXT,   -- room type / SKU
    "CANT"              INT,
    "PRECIO"            NUMERIC,
    "TOTAL"             NUMERIC,
    "PAXA"              INT,
    "PAXN"              INT
);

COMMENT ON TABLE bronze_reservas_raw IS
    'Untyped mirror of the legacy PMS export. Read only by refresh_silver(); never by reporting.';



-- ─────────────────────────────────────────────────────────────────────────────
-- IMMUTABLE DATE PARSER
-- ─────────────────────────────────────────────────────────────────────────────
-- Needed so the incremental delete can be index-supported.
--
-- TO_DATE() is only STABLE, not IMMUTABLE: with some format masks its result
-- depends on session settings, so Postgres refuses to build an index on an
-- expression containing it —
--
--     ERROR: functions in index expression must be marked IMMUTABLE
--
-- 'DD/MM/YYYY' is fully explicit and has no session dependence, so wrapping the
-- call in a function declared IMMUTABLE is sound for this mask specifically.
-- The wrapper is what the index in 02_indexes.sql is built on, and what
-- delete_bronze_rango() filters with — the index expression and the predicate
-- have to be written identically or the planner will not match them.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION f_fecha(txt TEXT)
RETURNS DATE
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$ SELECT TO_DATE(txt, 'DD/MM/YYYY') $$;
