/*
================================================================================
 SILVER — BRONZE TO NORMALISED 3NF
================================================================================
 Layer: Silver (transformation)
 Run:   After 01, 02 and 03. This is the logged version of the function; an
        earlier unlogged one was superseded.

 PARAMETER
   tc_dolar — USD→PEN rate. Passed in rather than stored, so a historical
   reload replays at the rate in force instead of repricing old bookings.

 FULL REBUILD, NOT MERGE
   Silver is truncated and rebuilt from the whole of Bronze on every run. At
   this volume that costs seconds and makes the load idempotent by
   construction — no late-arriving correction can leave a stale row behind.
   The incremental part of the pipeline is the Bronze window, which is where
   the data volume is.

 TRANSFORMATIONS
   - Customer deduplication by national ID, keeping the earliest creation date
     so fecha_primera_reserva reflects genuine first contact
   - Booking deduplication by (booking ID, creation year), because the source
     recycles IDRESERVA annually
   - Room-number collision offset
   - Currency normalisation to PEN
   - Header aggregate backfill from detail rows

 OBSERVABILITY
   One etl_log row per run, written on entry and updated on exit with row
   counts and elapsed seconds. The EXCEPTION block records SQLERRM before
   re-raising, so a failed load leaves a diagnosable trail.
================================================================================
*/

CREATE OR REPLACE FUNCTION refresh_silver(tc_dolar NUMERIC DEFAULT 3.0)
RETURNS TABLE (
    clientes_insertados   INT,
    reservas_insertadas   INT,
    detalles_insertados   INT
) AS $$
DECLARE
    v_clientes INT;
    v_reservas INT;
    v_detalles INT;
    v_inicio   TIMESTAMP := NOW();
    v_log_id   INT;
BEGIN
    -- Registrar inicio
    INSERT INTO etl_log (proceso, accion, estado, fecha_inicio)
    VALUES ('refresh_silver', 'START', 'OK', v_inicio)
    RETURNING log_id INTO v_log_id;

    -- Limpiar silver
    TRUNCATE reservas_detalle, reservas, clientes RESTART IDENTITY CASCADE;

    -- CLIENTES
    INSERT INTO clientes (dni, nombre, telefono, fecha_primera_reserva)
    SELECT DISTINCT ON (b."DNI")
        b."DNI", INITCAP(LOWER(b."NOMBRE")), b."TELEFONO_CELULAR",
        TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY')
    FROM bronze_reservas_raw b
    WHERE b."DNI" IS NOT NULL AND b."DNI" <> ''
    ORDER BY b."DNI", TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY') ASC;
    GET DIAGNOSTICS v_clientes = ROW_COUNT;

    -- Actualizar país origen
    UPDATE clientes 
    SET pais_origen = CASE WHEN dni ~ '^\d{8}$' THEN 'Perú' ELSE 'Extranjero' END;

    -- RESERVAS
    INSERT INTO reservas (id_reserva_origen, anio_creacion, hotel_id, cliente_id,
                          fecha_creacion, canal, sub_canal, asesor_reserva,
                          id_usuario_asesor, estado_codigo, estado_reserva,
                          estado_pago, moneda, fecha_carga)
    SELECT DISTINCT ON (b."IDRESERVA", 
                        EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT)
        b."IDRESERVA",
        EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT,
        b."IDHOTEL", c.cliente_id,
        (TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY') + b."HORA_CREACION"::TIME),
        b."DESCRIPCION", b."SUB CANAL",
        INITCAP(LOWER(b."ASESOR_RESERVA")),
        b."IDUSUARIO", b."ESTADO", b."ESTADORESERVA",
        b."ESTADOPAGO", b."MONEDA", NOW()
    FROM bronze_reservas_raw b
    JOIN clientes c ON c.dni = b."DNI"
    ORDER BY b."IDRESERVA",
             EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT,
             TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY') ASC,
             b."HORA_CREACION" ASC;
    GET DIAGNOSTICS v_reservas = ROW_COUNT;

    -- DETALLES
    INSERT INTO reservas_detalle (id_reserva_origen, anio_creacion, fecha,
                                  habitacion_numero, tipo_habitacion,
                                  cantidad, precio, total, pax_adultos, pax_ninos)
    SELECT
        sub.id_reserva_origen, sub.anio_creacion, sub.fecha,
        CASE WHEN sub.colision_rn > 1 
             THEN sub.habitacion_numero + 1000 * (sub.colision_rn - 1)
             ELSE sub.habitacion_numero END,
        sub.tipo_habitacion, sub.cantidad, sub.precio, sub.total,
        sub.pax_adultos, sub.pax_ninos
    FROM (
        SELECT
            b."IDRESERVA" AS id_reserva_origen,
            EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT AS anio_creacion,
            TO_DATE(b."FECHA", 'DD/MM/YYYY') AS fecha,
            b."NUMERO" AS habitacion_numero,
            b."DESCRIPCION1" AS tipo_habitacion,
            b."CANT" AS cantidad,
            b."PRECIO" AS precio,
            CASE WHEN UPPER(b."MONEDA") IN ('DOLARES','DÓLARES','USD')
                 THEN b."TOTAL" * tc_dolar ELSE b."TOTAL" END AS total,
            b."PAXA" AS pax_adultos,
            b."PAXN" AS pax_ninos,
            ROW_NUMBER() OVER (
                PARTITION BY b."IDRESERVA",
                             EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT,
                             TO_DATE(b."FECHA", 'DD/MM/YYYY'), b."NUMERO"
                ORDER BY b."DESCRIPCION1", b.ctid
            ) AS colision_rn
        FROM bronze_reservas_raw b
    ) sub
    WHERE EXISTS (
        SELECT 1 FROM reservas r
        WHERE r.id_reserva_origen = sub.id_reserva_origen
          AND r.anio_creacion     = sub.anio_creacion
    );
    GET DIAGNOSTICS v_detalles = ROW_COUNT;

    -- Agregados en reservas
    UPDATE reservas r
    SET noches_total   = sub.n_filas,
        total_reserva  = sub.total_sum,
        fecha_checkin  = sub.f_min,
        fecha_checkout = sub.f_max + INTERVAL '1 day',
        noches_estadia = sub.dias_unicos
    FROM (
        SELECT id_reserva_origen, anio_creacion,
               COUNT(*) AS n_filas,
               SUM(total) AS total_sum,
               MIN(fecha) AS f_min,
               MAX(fecha) AS f_max,
               COUNT(DISTINCT fecha) AS dias_unicos
        FROM reservas_detalle
        GROUP BY id_reserva_origen, anio_creacion
    ) sub
    WHERE r.id_reserva_origen = sub.id_reserva_origen
      AND r.anio_creacion     = sub.anio_creacion;

UPDATE reservas_detalle
SET
    dia = EXTRACT(DAY FROM fecha),
    mes = EXTRACT(MONTH FROM fecha),
    año = EXTRACT(YEAR FROM fecha);

    -- Registrar fin exitoso
    UPDATE etl_log 
    SET estado = 'OK',
        fecha_fin = NOW(),
        duracion_segundos = EXTRACT(EPOCH FROM (NOW() - v_inicio)),
        filas_afectadas = v_clientes + v_reservas + v_detalles,
        mensaje = FORMAT('Clientes: %s, Reservas: %s, Detalles: %s', 
                         v_clientes, v_reservas, v_detalles)
    WHERE log_id = v_log_id;

    RETURN QUERY SELECT v_clientes, v_reservas, v_detalles;

EXCEPTION WHEN OTHERS THEN
    -- Registrar error si algo explota
    UPDATE etl_log 
    SET estado = 'ERROR',
        fecha_fin = NOW(),
        duracion_segundos = EXTRACT(EPOCH FROM (NOW() - v_inicio)),
        mensaje = SQLERRM
    WHERE log_id = v_log_id;
    RAISE;
END;
$$ LANGUAGE plpgsql;
