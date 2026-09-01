/*
================================================================================
 GOVERNANCE — DATA QUALITY AND PIPELINE MONITORING
================================================================================
 Layer: Governance

 Automated health checks run after every load. Each returns a count plus a
 traffic-light status, so a single SELECT answers "is today's data trustworthy?".

 DESIGN
   Checks are UNION ALL'd into one result set rather than split into separate
   views, so the whole suite pins to a dashboard as one query and any regression
   is visible at a glance.

 SEVERITY MODEL
   Thresholds are per check, not global. An orphaned record is critical at any
   count because it means referential integrity broke. A hotel without a city is
   a warning — a new property simply has not been enriched yet.

 CHECKS 11–13 ARE NEW, AND 6 WAS REWRITTEN — see the comments inline.
================================================================================
*/

CREATE OR REPLACE VIEW v_health_check AS

-- Chequeo 1: reservas huérfanas (con cliente_id que no existe)
SELECT 
    'Reservas huérfanas (cliente_id inválido)' AS chequeo,
    COUNT(*) AS conteo,
    CASE WHEN COUNT(*) = 0 THEN '🟢 OK' 
         WHEN COUNT(*) <= 10 THEN '🟡 ATENCIÓN'
         ELSE '🔴 CRÍTICO' END AS estado
FROM reservas r
WHERE NOT EXISTS (SELECT 1 FROM clientes c WHERE c.cliente_id = r.cliente_id)

UNION ALL

-- Chequeo 2: detalles huérfanos (sin reserva)
SELECT 
    'Detalles huérfanos (sin reserva)',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN '🟢 OK' ELSE '🔴 CRÍTICO' END
FROM reservas_detalle rd
WHERE NOT EXISTS (
    SELECT 1 FROM reservas r 
    WHERE r.id_reserva_origen = rd.id_reserva_origen 
      AND r.anio_creacion = rd.anio_creacion
)

UNION ALL

-- Chequeo 3: precios negativos
SELECT 
    'Detalles con precio negativo',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN '🟢 OK' 
         WHEN COUNT(*) <= 5 THEN '🟡 ATENCIÓN'
         ELSE '🔴 CRÍTICO' END
FROM reservas_detalle
WHERE precio < 0 OR total < 0

UNION ALL

-- Chequeo 4: DNIs duplicados
SELECT 
    'DNIs duplicados en clientes',
    COUNT(*) - COUNT(DISTINCT dni),
    CASE WHEN COUNT(*) - COUNT(DISTINCT dni) = 0 THEN '🟢 OK' 
         ELSE '🔴 CRÍTICO' END
FROM clientes

UNION ALL

-- Chequeo 5: hoteles sin ciudad (dim incompleta)
SELECT 
    'Hoteles sin ciudad',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN '🟢 OK' 
         WHEN COUNT(*) <= 2 THEN '🟡 ATENCIÓN'
         ELSE '🔴 CRÍTICO' END
FROM hoteles
WHERE ciudad IS NULL

UNION ALL

-- Chequeo 6: canales sin clasificar
-- FIX: this counted dim_canal rows flagged 'Sin clasificar', but dim_canal is
-- loaded from a fixed seed list in which no row carries that value, so the
-- count was structurally always zero and the check could never fire. What has
-- to be detected is a channel present in the DATA and absent from the
-- dimension — its revenue falls out of every team-filtered report.
SELECT 
    'Canales en reservas sin fila en dim_canal',
    COUNT(DISTINCT r.canal),
    CASE WHEN COUNT(DISTINCT r.canal) = 0 THEN '🟢 OK' ELSE '🟡 ATENCIÓN' END
FROM reservas r
WHERE r.canal IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dim_canal dc WHERE dc.nombre_canal = r.canal)

UNION ALL

-- Chequeo 7: reservas sin hotel_id válido
SELECT 
    'Reservas con hotel inexistente',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN '🟢 OK' ELSE '🔴 CRÍTICO' END
FROM reservas r
WHERE NOT EXISTS (SELECT 1 FROM hoteles h WHERE h.hotel_id = r.hotel_id)

UNION ALL

-- Chequeo 8: última carga OK
SELECT 
    'Última carga completada',
    1,
    CASE 
        WHEN NOT EXISTS (SELECT 1 FROM etl_log WHERE proceso = 'refresh_silver')
        THEN '🟡 NUNCA EJECUTADA'
        WHEN (SELECT estado FROM etl_log 
              WHERE proceso = 'refresh_silver' 
              ORDER BY fecha_inicio DESC LIMIT 1) = 'ERROR'
        THEN '🔴 ERROR EN ÚLTIMA'
        WHEN (SELECT fecha_inicio FROM etl_log 
              WHERE proceso = 'refresh_silver' 
              ORDER BY fecha_inicio DESC LIMIT 1) < NOW() - INTERVAL '2 days'
        THEN '🟡 HACE MÁS DE 2 DÍAS'
        ELSE '🟢 OK'
    END

UNION ALL

-- Chequeo 9: reservas con montos anómalos (extremadamente altos)
SELECT 
    'Reservas con total > 150k soles (revisar)',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN '🟢 OK' 
         WHEN COUNT(*) <= 3 THEN '🟡 ATENCIÓN'
         ELSE '🔴 CRÍTICO' END
FROM reservas
WHERE total_reserva > 150000

UNION ALL

-- Chequeo 10: reservas con fecha_checkout antes de checkin
SELECT 
    'Reservas con checkout < checkin (imposible)',
    COUNT(*),
    CASE WHEN COUNT(*) = 0 THEN '🟢 OK' ELSE '🔴 CRÍTICO' END
FROM reservas
WHERE fecha_checkout < fecha_checkin

UNION ALL

-- Chequeo 11: asesores presentes en los datos y ausentes de la dimensión.
-- Toda vista de producción hace INNER JOIN a dim_asesor, así que un asesor
-- faltante no levanta error: su producción entera desaparece del reporte.
-- Subestimar en silencio es el modo de falla que nadie nota.
SELECT
    'Asesores en reservas sin fila en dim_asesor',
    COUNT(DISTINCT r.id_usuario_asesor),
    CASE WHEN COUNT(DISTINCT r.id_usuario_asesor) = 0 THEN '🟢 OK' ELSE '🔴 CRÍTICO' END
FROM reservas r
WHERE r.id_usuario_asesor IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM dim_asesor da WHERE da.id_usuario_origen = r.id_usuario_asesor
  )

UNION ALL

-- Chequeo 12: tipos de habitación en los datos y ausentes de la dimensión.
-- Mismo modo de falla del chequeo 11, sobre las vistas de ocupabilidad.
SELECT
    'Tipos de habitación sin fila en dim_tipo_habitacion',
    COUNT(DISTINCT rd.tipo_habitacion),
    CASE WHEN COUNT(DISTINCT rd.tipo_habitacion) = 0 THEN '🟢 OK' ELSE '🔴 CRÍTICO' END
FROM reservas_detalle rd
WHERE rd.tipo_habitacion IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM dim_tipo_habitacion dth WHERE dth.nombre_tipo = rd.tipo_habitacion
  )

UNION ALL

-- Chequeo 13: reconciliación bronze → silver. El único chequeo que prueba que
-- la carga no duplicó ni perdió reservas: los pares (reserva, año) distintos
-- en staging deben igualar las cabeceras en silver.
SELECT
    'Descuadre reservas bronze vs silver',
    ABS(
        (SELECT COUNT(DISTINCT ("IDRESERVA",
                                EXTRACT(YEAR FROM TO_DATE("FECHA_CREACION",'DD/MM/YYYY'))::INT))
         FROM bronze_reservas_raw b
         WHERE b."DNI" IS NOT NULL AND b."DNI" <> ''
           AND EXISTS (SELECT 1 FROM hoteles h WHERE h.hotel_id = b."IDHOTEL"))
        - (SELECT COUNT(*) FROM reservas)
    ),
    CASE WHEN ABS(
        (SELECT COUNT(DISTINCT ("IDRESERVA",
                                EXTRACT(YEAR FROM TO_DATE("FECHA_CREACION",'DD/MM/YYYY'))::INT))
         FROM bronze_reservas_raw b
         WHERE b."DNI" IS NOT NULL AND b."DNI" <> ''
           AND EXISTS (SELECT 1 FROM hoteles h WHERE h.hotel_id = b."IDHOTEL"))
        - (SELECT COUNT(*) FROM reservas)
    ) = 0 THEN '🟢 OK' ELSE '🔴 CRÍTICO' END;


CREATE OR REPLACE VIEW v_carga_reciente AS
SELECT 
    log_id,
    proceso,
    accion,
    filas_afectadas,
    estado,
    ROUND(duracion_segundos, 2) AS segundos,
    TO_CHAR(fecha_inicio, 'DD/MM/YYYY HH24:MI:SS') AS inicio,
    mensaje
FROM etl_log
ORDER BY fecha_inicio DESC
LIMIT 50;


CREATE OR REPLACE VIEW v_carga_stats AS
SELECT 
    proceso,
    COUNT(*)                                     AS total_ejecuciones,
    COUNT(*) FILTER (WHERE estado = 'OK')        AS exitosas,
    COUNT(*) FILTER (WHERE estado = 'ERROR')     AS fallidas,
    ROUND(AVG(duracion_segundos)::NUMERIC, 2)    AS duracion_promedio_seg,
    ROUND(MAX(duracion_segundos)::NUMERIC, 2)    AS duracion_maxima_seg,
    MAX(fecha_inicio)                            AS ultima_ejecucion
FROM etl_log
WHERE fecha_inicio >= NOW() - INTERVAL '30 days'
GROUP BY proceso;
