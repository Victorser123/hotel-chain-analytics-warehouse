/*
================================================================================
 SILVER — DERIVED DIMENSIONS
================================================================================
 Layer: Silver
 Run:   AFTER the first refresh_silver(). These two dimensions are populated
        from loaded fact data, which is the circular dependency in the model:
        the fact tables need the dimensions to be reportable, and the dimensions
        need the fact tables to be populated.

 Both are one-off bootstrap loads. New agents and new room types appearing in
 later loads are NOT picked up automatically — checks 11 and 12 in
 v_health_check exist to catch that, because a missing dimension member does
 not raise an error, it just removes that agent's production or that SKU's
 nights from every report. Re-run this file (with the INSERTs made
 ON CONFLICT DO NOTHING) or fold it into refresh_silver() to close the gap.
================================================================================
*/
-- ─────────────────────────────────────────────────────────────────────────────
-- SALES AGENT DIMENSION
-- ─────────────────────────────────────────────────────────────────────────────
-- Keyed on the source user ID, never the agent name. Names arrive with
-- inconsistent casing and accent corruption, so the same person appears under
-- several spellings and a text join fragments their production across variants.
-- The numeric ID is stable.
--
-- DISTINCT ON keeps the most recent spelling of each agent's name.
--
---- ─────────────────────────────────────────────────────────────────────────────


INSERT INTO dim_asesor (id_usuario_origen, nombre_asesor, area_trabajo)
SELECT DISTINCT ON (b."IDUSUARIO")
    b."IDUSUARIO"                                     AS id_usuario_origen,
    INITCAP(LOWER(b."ASESOR_RESERVA"))                AS nombre_asesor,
    CASE 
        WHEN b."DESCRIPCION" IN ('CENTRAL DE RESERVAS','PAGINA WEB PROPIA',
                                  'PAGINA ONLINE TERCEROS (OTAS)','POR TERCEROS',
                                  'AGENCIAS','REDES SOCIALES','DIRECCION DE VENTAS',
                                  'OTROS') THEN 'Área Reservas'
        WHEN b."DESCRIPCION" = 'SOCIOS VIP' THEN 'Socios'
        WHEN b."DESCRIPCION" IN ('EN HOTEL','WALKING','RESERVA EN HOTEL') THEN 'Hotel'
        ELSE 'Sin clasificar'
    END                                               AS area_trabajo
FROM bronze_reservas_raw b
WHERE b."IDUSUARIO" IS NOT NULL 
  AND b."IDUSUARIO" > 0
  AND b."ASESOR_RESERVA" IS NOT NULL
ORDER BY b."IDUSUARIO", 
         TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY') DESC,
         b."HORA_CREACION" DESC;



-- ─────────────────────────────────────────────────────────────────────────────
-- ROOM TYPE DIMENSION
-- ─────────────────────────────────────────────────────────────────────────────
-- The source mixes lodging with event products — tents, party packages, lobby
-- rentals, entry tickets — in the same column. Before this dimension every
-- reporting view carried an identical 15-item NOT IN list, impossible to keep
-- in sync. Categorising once turns that into WHERE categoria = 'Habitacion'.
--
-- Both spellings of CABAÑA are listed on purpose. The source exports the same
-- value under two encodings, one of which arrives mojibaked, and dropping
-- either one silently excludes those rooms from occupancy.
--
-- Run after the first refresh_silver().
-- ─────────────────────────────────────────────────────────────────────────────


INSERT INTO dim_tipo_habitacion (nombre_tipo, categoria)
SELECT DISTINCT 
    tipo_habitacion,
    CASE 
        WHEN tipo_habitacion IN ('FAMILIAR', 'SUITE', 'SUITE PRESIDENCIAL', 'CABA�A', 'MATRIMONIAL', 'TRIPLE', 'CABAÑA', 'PRESIDENCIAL') 
        THEN  'Habitacion'
        WHEN tipo_habitacion IN ('~CARPAS ARIERO','~CARPAS') 
        THEN 'Carpa' 
        ELSE 'Otros'
    END 
FROM reservas_detalle
WHERE tipo_habitacion IS NOT NULL;



