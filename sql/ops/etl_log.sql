/*
================================================================================
 OPS — ETL AUDIT LOG
================================================================================
 Run: Before any pipeline function; all of them write here on entry.

 One row per pipeline step per run, updated on exit with row counts and elapsed
 seconds. The EXCEPTION block in each function records SQLERRM here before
 re-raising, so a failed load leaves a diagnosable trail instead of vanishing.
================================================================================
*/

CREATE TABLE etl_log (
    log_id              SERIAL PRIMARY KEY,
    proceso             TEXT NOT NULL,       -- 'cargador_vba', 'refresh_silver', 'refresh_gold'
    accion              TEXT NOT NULL,       -- 'INSERT_BRONZE', 'DELETE_RANGO', 'REFRESH_MV', etc.
    filas_afectadas     INT,
    estado              TEXT NOT NULL,       -- 'OK' / 'ERROR' / 'WARNING'
    mensaje             TEXT,                -- detalle del error si aplica
    duracion_segundos   NUMERIC(10,2),
    fecha_inicio        TIMESTAMP DEFAULT NOW(),
    fecha_fin           TIMESTAMP
);

CREATE INDEX idx_etl_log_fecha  ON etl_log(fecha_inicio DESC);
CREATE INDEX idx_etl_log_estado ON etl_log(estado);
