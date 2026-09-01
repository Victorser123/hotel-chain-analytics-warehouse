/*
================================================================================
 BRONZE — INDEXES
================================================================================
 Run: After 01_landing_table.sql.

 FIX — THESE ARE NOW EXPRESSION INDEXES
 --------------------------------------
 The previous definition was:

     CREATE INDEX idx_bronze_fecha ON bronze_reservas_raw (("FECHA"));

 which indexes the raw text. delete_bronze_rango() filters on
 TO_DATE("FECHA", 'DD/MM/YYYY'), and the planner cannot use a plain index on
 the underlying column for a predicate over a function of it — so the index was
 built, maintained on every load, and never once used. The index has to be on
 the same expression the planner sees. to_date() is IMMUTABLE, which is what
 makes that legal.

 Verify the index is actually chosen:

   EXPLAIN ANALYZE DELETE FROM bronze_reservas_raw
   WHERE f_fecha("FECHA") BETWEEN '2025-01-01' AND '2025-01-31';

 AND WHY IT IS f_fecha() AND NOT TO_DATE()
 -----------------------------------------
 Indexing TO_DATE() directly fails:

     ERROR: functions in index expression must be marked IMMUTABLE

 TO_DATE() is STABLE, because for some format masks its result depends on
 session settings. 'DD/MM/YYYY' has no such dependence, so f_fecha() (defined
 in 01_landing_table.sql) wraps that one call and is declared IMMUTABLE. The
 predicate in delete_bronze_rango() was changed to use the same wrapper: an
 expression index is only usable when the query spells the expression exactly
 the way the index was built.
================================================================================
*/

CREATE INDEX IF NOT EXISTS idx_bronze_fecha
    ON bronze_reservas_raw ((f_fecha("FECHA")));

CREATE INDEX IF NOT EXISTS idx_bronze_fecha_creac
    ON bronze_reservas_raw ((f_fecha("FECHA_CREACION")));

