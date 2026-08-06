/*
================================================================
ETL PIPELINE — Bronze → Silver → Gold
================================================================
AUTHOR: Victor Sernaque
LAYER:  Orchestration

PIPELINE FLOW:
  1. delete_bronze_rango(f_min, f_max)  → clear the reload window
  2. [external] POST raw rows to bronze in batches
  3. refresh_silver(tc_dolar)           → normalise into 3NF
  4. refresh_gold()                     → refresh materialised views

WHY FUNCTIONS:
  Exposes the pipeline as RPC endpoints the external loader can call,
  and keeps multi-step business logic versioned alongside the schema.

OBSERVABILITY:
  Every function writes to etl_log on entry and updates the same row
  on exit, including elapsed seconds and row counts. The EXCEPTION
  block records SQLERRM before re-raising, so a failed load leaves a
  diagnosable trail instead of vanishing.
================================================================
*/

-- ============================================================
-- ETL AUDIT LOG
-- ============================================================
CREATE TABLE etl_log (
    log_id            SERIAL PRIMARY KEY,
    proceso           TEXT NOT NULL,   -- 'cargador_vba' | 'refresh_silver' | 'refresh_gold'
    accion            TEXT NOT NULL,   -- 'START' | 'DELETE_RANGO' | 'REFRESH_MV'
    filas_afectadas   INT,
    estado            TEXT NOT NULL,   -- 'OK' | 'ERROR' | 'WARNING'
    mensaje           TEXT,            -- SQLERRM on failure, summary on success
    duracion_segundos NUMERIC(10,2),
    fecha_inicio      TIMESTAMP DEFAULT NOW(),
    fecha_fin         TIMESTAMP
);


-- ============================================================
-- BRONZE — INCREMENTAL DELETE
-- ============================================================
/*
  Deletes the reload window from the raw staging table.

  Filtering by creation date would remove bookings created inside the
  window but staying outside it, dropping revenue from months that are
  not being reloaded — with no error raised.

  Wrapped in a function because PostgREST cannot apply TO_DATE()
  inside a filter predicate, and bronze stores dates as TEXT
  (DD/MM/YYYY) to stay a faithful mirror of the untyped source export.
*/
CREATE OR REPLACE FUNCTION delete_bronze_rango(f_min DATE, f_max DATE)
RETURNS INT AS $$
DECLARE
    v_count  INT;
    v_inicio TIMESTAMP := NOW();
    v_log_id INT;
BEGIN
    INSERT INTO etl_log (proceso, accion, estado, fecha_inicio, mensaje)
    VALUES ('cargador_vba', 'DELETE_RANGO', 'OK', v_inicio,
            FORMAT('Rango %s a %s', f_min, f_max))
    RETURNING log_id INTO v_log_id;

    DELETE FROM bronze_reservas_raw
    WHERE TO_DATE("FECHA", 'DD/MM/YYYY') BETWEEN f_min AND f_max;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    UPDATE etl_log
    SET fecha_fin         = NOW(),
        duracion_segundos = EXTRACT(EPOCH FROM (NOW() - v_inicio)),
        filas_afectadas   = v_count
    WHERE log_id = v_log_id;

    RETURN v_count;

EXCEPTION WHEN OTHERS THEN
    UPDATE etl_log
    SET estado    = 'ERROR',
        fecha_fin = NOW(),
        mensaje   = SQLERRM
    WHERE log_id = v_log_id;
    RAISE;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- SILVER — BRONZE TO NORMALISED 3NF
-- ============================================================
/*
  Rebuilds the silver layer from bronze in a single transaction.

  PARAMETER:
    tc_dolar — USD→PEN exchange rate. Passed in rather than stored
    so that historical reloads can be replayed at the rate that was
    in force, instead of silently repricing old bookings.

  TRANSFORMATIONS:
    - Customer deduplication by national ID
    - Booking deduplication by (booking ID, year)
    - Room-number collision resolution
    - Currency normalisation to PEN
    - Header aggregate backfill from detail rows

  Each is explained at the block where it is applied.
*/
CREATE OR REPLACE FUNCTION refresh_silver(tc_dolar NUMERIC DEFAULT 3.0)
RETURNS TABLE (
    clientes_insertados INT,
    reservas_insertadas INT,
    detalles_insertados INT
) AS $$
DECLARE
    v_clientes INT;
    v_reservas INT;
    v_detalles INT;
    v_inicio   TIMESTAMP := NOW();
    v_log_id   INT;
BEGIN
    INSERT INTO etl_log (proceso, accion, estado, fecha_inicio)
    VALUES ('refresh_silver', 'START', 'OK', v_inicio)
    RETURNING log_id INTO v_log_id;

    -- Truncate in FK-safe order
    TRUNCATE reservas_detalle, reservas, clientes RESTART IDENTITY CASCADE;

    -- ── CUSTOMERS — dedup by DNI, keeping earliest creation date ──
    -- Keeping the earliest row means fecha_primera_reserva reflects
    -- genuine first contact, not whichever row happened to sort first.
    INSERT INTO clientes (dni, nombre, telefono, fecha_primera_reserva)
    SELECT DISTINCT ON (b."DNI")
        b."DNI",
        INITCAP(LOWER(b."NOMBRE")),
        b."TELEFONO_CELULAR",
        TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY')
    FROM bronze_reservas_raw b
    WHERE b."DNI" IS NOT NULL
      AND b."DNI" <> ''
    ORDER BY b."DNI", TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY') ASC;
    GET DIAGNOSTICS v_clientes = ROW_COUNT;

    -- Derive origin: Peruvian DNI is exactly 8 digits
    UPDATE clientes
    SET pais_origen = CASE WHEN dni ~ '^\d{8}$' THEN 'Perú' ELSE 'Extranjero' END;

    -- ── BOOKING HEADERS — dedup by (booking ID, year) ──
    -- The source system recycles IDRESERVA annually, so the year must
    -- be part of the dedup key or bookings from different years
    -- collapse into a single row.
    INSERT INTO reservas (
        id_reserva_origen, anio_creacion, hotel_id, cliente_id,
        fecha_creacion, canal, sub_canal, asesor_reserva,
        id_usuario_asesor, estado_codigo, estado_reserva,
        estado_pago, moneda, fecha_carga
    )
    SELECT DISTINCT ON (
        b."IDRESERVA",
        EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT
    )
        b."IDRESERVA",
        EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT,
        b."IDHOTEL",
        c.cliente_id,
        (TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY') + b."HORA_CREACION"::TIME),
        b."DESCRIPCION",
        b."SUB CANAL",
        INITCAP(LOWER(b."ASESOR_RESERVA")),
        b."IDUSUARIO",
        b."ESTADO",
        b."ESTADORESERVA",
        b."ESTADOPAGO",
        b."MONEDA",
        NOW()
    FROM bronze_reservas_raw b
    JOIN clientes c ON c.dni = b."DNI"
    ORDER BY
        b."IDRESERVA",
        EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT,
        TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY') ASC,
        b."HORA_CREACION" ASC;
    GET DIAGNOSTICS v_reservas = ROW_COUNT;

    -- ── BOOKING DETAIL — currency normalisation + collision offset ──
    /*
      Two transformations happen here:

      1. Room-number collision offset.
         The natural UNIQUE key (booking, year, date, room) is violated
         by legitimate source rows where one room is billed twice on the
         same night under different SKUs. ROW_NUMBER() detects the
         collision and offsets the room number by +1000 per duplicate,
         preserving revenue instead of discarding rows to satisfy the
         constraint.

      2. Currency normalisation.
         USD lines are converted to PEN at load time so every downstream
         SUM() is already in a single currency and no report needs to
         know about FX.
    */
    INSERT INTO reservas_detalle (
        id_reserva_origen, anio_creacion, fecha,
        habitacion_numero, tipo_habitacion,
        cantidad, precio, total, pax_adultos, pax_ninos
    )
    SELECT
        sub.id_reserva_origen,
        sub.anio_creacion,
        sub.fecha,
        CASE
            WHEN sub.colision_rn > 1
            THEN sub.habitacion_numero + 1000 * (sub.colision_rn - 1)
            ELSE sub.habitacion_numero
        END,
        sub.tipo_habitacion,
        sub.cantidad,
        sub.precio,
        sub.total,
        sub.pax_adultos,
        sub.pax_ninos
    FROM (
        SELECT
            b."IDRESERVA"                                                     AS id_reserva_origen,
            EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT AS anio_creacion,
            TO_DATE(b."FECHA", 'DD/MM/YYYY')                                  AS fecha,
            b."NUMERO"                                                        AS habitacion_numero,
            b."DESCRIPCION1"                                                  AS tipo_habitacion,
            b."CANT"                                                          AS cantidad,
            b."PRECIO"                                                        AS precio,
            CASE
                WHEN UPPER(b."MONEDA") IN ('DOLARES', 'DÓLARES', 'USD')
                THEN b."TOTAL" * tc_dolar
                ELSE b."TOTAL"
            END                                                               AS total,
            b."PAXA"                                                          AS pax_adultos,
            b."PAXN"                                                          AS pax_ninos,
            ROW_NUMBER() OVER (
                PARTITION BY
                    b."IDRESERVA",
                    EXTRACT(YEAR FROM TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY'))::INT,
                    TO_DATE(b."FECHA", 'DD/MM/YYYY'),
                    b."NUMERO"
                ORDER BY b."DESCRIPCION1", b.ctid
            )                                                                 AS colision_rn
        FROM bronze_reservas_raw b
    ) sub
    WHERE EXISTS (
        SELECT 1 FROM reservas r
        WHERE r.id_reserva_origen = sub.id_reserva_origen
          AND r.anio_creacion     = sub.anio_creacion
    );
    GET DIAGNOSTICS v_detalles = ROW_COUNT;

    -- ── HEADER AGGREGATE BACKFILL — anti fan-out denormalisation ──
    -- Check-in, check-out, night count and booking total are computed
    -- from the detail rows and written back to the header. Deliberate
    -- denormalisation: it lets header-grain reports answer revenue
    -- questions without joining the line table, which is the single
    -- most common source of fan-out errors in this dataset.
    UPDATE reservas r
    SET noches_total   = sub.n_filas,
        total_reserva  = sub.total_sum,
        fecha_checkin  = sub.f_min,
        fecha_checkout = sub.f_max + INTERVAL '1 day',
        noches_estadia = sub.dias_unicos
    FROM (
        SELECT
            id_reserva_origen,
            anio_creacion,
            COUNT(*)              AS n_filas,
            SUM(total)            AS total_sum,
            MIN(fecha)            AS f_min,
            MAX(fecha)            AS f_max,
            COUNT(DISTINCT fecha) AS dias_unicos
        FROM reservas_detalle
        GROUP BY id_reserva_origen, anio_creacion
    ) sub
    WHERE r.id_reserva_origen = sub.id_reserva_origen
      AND r.anio_creacion     = sub.anio_creacion;

    -- Materialise date parts for BI tools with limited pushdown
    UPDATE reservas_detalle
    SET dia   = EXTRACT(DAY   FROM fecha),
        mes   = EXTRACT(MONTH FROM fecha),
        "año" = EXTRACT(YEAR  FROM fecha);

    -- Close the log entry
    UPDATE etl_log
    SET estado            = 'OK',
        fecha_fin         = NOW(),
        duracion_segundos = EXTRACT(EPOCH FROM (NOW() - v_inicio)),
        filas_afectadas   = v_clientes + v_reservas + v_detalles,
        mensaje           = FORMAT('Clientes: %s, Reservas: %s, Detalles: %s',
                                   v_clientes, v_reservas, v_detalles)
    WHERE log_id = v_log_id;

    RETURN QUERY SELECT v_clientes, v_reservas, v_detalles;

EXCEPTION WHEN OTHERS THEN
    UPDATE etl_log
    SET estado            = 'ERROR',
        fecha_fin         = NOW(),
        duracion_segundos = EXTRACT(EPOCH FROM (NOW() - v_inicio)),
        mensaje           = SQLERRM
    WHERE log_id = v_log_id;
    RAISE;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- GOLD — MATERIALISED VIEW REFRESH
-- ============================================================
/*
  Wrapped in a function because PostgREST cannot issue
  REFRESH MATERIALIZED VIEW directly. Logged like every other step
  for end-to-end pipeline visibility.
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

    REFRESH MATERIALIZED VIEW mv_cliente_metricas;

    UPDATE etl_log
    SET fecha_fin         = NOW(),
        duracion_segundos = EXTRACT(EPOCH FROM (NOW() - v_inicio)),
        mensaje           = 'mv_cliente_metricas refreshed'
    WHERE log_id = v_log_id;

    RETURN 'OK';

EXCEPTION WHEN OTHERS THEN
    UPDATE etl_log
    SET estado    = 'ERROR',
        fecha_fin = NOW(),
        mensaje   = SQLERRM
    WHERE log_id = v_log_id;
    RAISE;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- GOLD — CUSTOMER METRICS MATERIALISED VIEW
-- ============================================================
/*
  Materialised rather than a plain view because it aggregates the full
  booking history and is read by several dashboards; refreshing once
  per load is far cheaper than recomputing per query.

  Bookings that are simultaneously unpaid AND still in 'Reservado'
  status are excluded: they are holds that were never confirmed, and
  counting them inflates every revenue metric.
*/
CREATE MATERIALIZED VIEW mv_cliente_metricas AS
SELECT
    r.cliente_id,

    -- Lifetime metrics
    COUNT(*)                    AS total_reservas,
    SUM(r.total_reserva)        AS total_gastado,
    MIN(r.fecha_creacion)::DATE AS fecha_primera_reserva,
    MAX(r.fecha_creacion)::DATE AS fecha_ultima_reserva,

    -- Current-year metrics
    COUNT(*) FILTER (
        WHERE EXTRACT(YEAR FROM r.fecha_checkin) = EXTRACT(YEAR FROM CURRENT_DATE)
    ) AS total_reservas_anio_actual,

    SUM(r.total_reserva) FILTER (
        WHERE EXTRACT(YEAR FROM r.fecha_checkin) = EXTRACT(YEAR FROM CURRENT_DATE)
    ) AS total_gastado_anio_actual,

    (COUNT(*) FILTER (
        WHERE EXTRACT(YEAR FROM r.fecha_checkin) = EXTRACT(YEAR FROM CURRENT_DATE)
    ) >= 1) AS tiene_reserva_anio_actual,

    -- Segmentation by lifetime booking count
    (COUNT(*) > 1) AS es_recurrente,
    CASE
        WHEN COUNT(*) = 1             THEN 'Nuevo'
        WHEN COUNT(*) BETWEEN 2 AND 3 THEN 'Ocasional'
        WHEN COUNT(*) BETWEEN 4 AND 9 THEN 'Fiel'
        WHEN COUNT(*) >= 10           THEN 'VIP'
    END AS segmento

FROM reservas r
WHERE NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
GROUP BY r.cliente_id;

-- UNIQUE index is required for REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX idx_mv_cliente_metricas ON mv_cliente_metricas(cliente_id);
