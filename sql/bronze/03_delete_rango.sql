/*
================================================================================
 BRONZE — INCREMENTAL DELETE
================================================================================
 Clears the reload window from staging before the loader posts the replacement
 batch. This is the logged version of the function; an earlier unlogged one was
 superseded.

 WHY STAY DATE AND NOT CREATION DATE
 -----------------------------------
 The window filters on "FECHA", the night of stay. Filtering on "FECHA_CREACION"
 would delete bookings created inside the window but staying outside it —
 removing revenue from months that were never being reloaded, with no error
 raised. (An earlier comment on this function described it as a delete by
 FECHA_CREACION, which never matched what the body actually did.)

 ONE LINE CHANGED FROM THE WORKING COPY
 --------------------------------------
 The predicate now calls f_fecha("FECHA") instead of
 TO_DATE("FECHA", 'DD/MM/YYYY'). Same result, but it matches the expression the
 Bronze index is built on — see 02_indexes.sql for why the index could not be
 built on TO_DATE() directly.

 WHY A FUNCTION
 --------------
 PostgREST cannot apply TO_DATE() inside a filter predicate, and Bronze stores
 dates as TEXT.
================================================================================
*/

CREATE OR REPLACE FUNCTION delete_bronze_rango(f_min DATE, f_max DATE)
RETURNS INT AS $$
DECLARE
    v_count INT;
    v_inicio TIMESTAMP := NOW();
    v_log_id INT;
BEGIN
    INSERT INTO etl_log (proceso, accion, estado, fecha_inicio, mensaje)
    VALUES ('cargador_vba', 'DELETE_RANGO', 'OK', v_inicio,
            FORMAT('Rango %s a %s', f_min, f_max))
    RETURNING log_id INTO v_log_id;

    DELETE FROM bronze_reservas_raw
    WHERE f_fecha("FECHA") BETWEEN f_min AND f_max;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    UPDATE etl_log 
    SET fecha_fin = NOW(),
        duracion_segundos = EXTRACT(EPOCH FROM (NOW() - v_inicio)),
        filas_afectadas = v_count
    WHERE log_id = v_log_id;

    RETURN v_count;
EXCEPTION WHEN OTHERS THEN
    UPDATE etl_log 
    SET estado = 'ERROR',
        fecha_fin = NOW(),
        mensaje = SQLERRM
    WHERE log_id = v_log_id;
    RAISE;
END;
$$ LANGUAGE plpgsql;
