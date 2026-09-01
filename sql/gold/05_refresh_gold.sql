/*
================================================================================
 GOLD — MATERIALISED VIEW REFRESH
================================================================================
 Wrapped in a function because PostgREST cannot issue REFRESH MATERIALIZED VIEW
 directly, and logged like every other step for end-to-end visibility.

 TWO CHANGES TO THE WORKING COPY

 1. fact_reservas is refreshed here too. It was created early and refreshed by
    hand; leaving it out of refresh_gold() meant the BI layer could read a
    snapshot older than the customer metrics beside it, with the two
    disagreeing and nothing explaining why.

 2. mv_cliente_metricas refreshes CONCURRENTLY. A plain refresh takes an ACCESS
    EXCLUSIVE lock and every dashboard reading the view blocks until the load
    finishes. The concurrent form needs a UNIQUE index on the view, which
    already exists — the index was created for exactly this and then not used.
    fact_reservas has no unique index and so still refreshes with a lock; give
    it one on (id_reserva_origen, anio_creacion, fecha, habitacion_numero) to
    make it concurrent too.
================================================================================
*/

CREATE OR REPLACE FUNCTION refresh_gold()
RETURNS TEXT AS $$
DECLARE
    v_inicio TIMESTAMP := NOW();
    v_log_id INT;
BEGIN
    INSERT INTO etl_log (proceso, accion, estado, fecha_inicio)
    VALUES ('refresh_gold', 'REFRESH_MV', 'OK', v_inicio)
    RETURNING log_id INTO v_log_id;

    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_cliente_metricas;
    REFRESH MATERIALIZED VIEW fact_reservas;

    UPDATE etl_log 
    SET fecha_fin = NOW(),
        duracion_segundos = EXTRACT(EPOCH FROM (NOW() - v_inicio)),
        mensaje = 'mv_cliente_metricas + fact_reservas refrescadas'
    WHERE log_id = v_log_id;

    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    UPDATE etl_log 
    SET estado = 'ERROR',
        fecha_fin = NOW(),
        mensaje = SQLERRM
    WHERE log_id = v_log_id;
    RAISE;
END;
$$ LANGUAGE plpgsql;
