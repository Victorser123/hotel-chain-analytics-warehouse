/*
================================================================================
 SCHEMA — DIMENSION TABLES
================================================================================
 Layer:    Gold (semantic)
 Purpose:  Business dimensions that enrich the normalized fact tables with
           analytical attributes and replace hardcoded filter lists.
 Run order: Two-phase bootstrap. dim_fecha and dim_canal are static and load
            immediately. dim_asesor and dim_tipo_habitacion derive from loaded
            data, so their INSERTs run after the first refresh_silver().
 Sequence: 02_core_tables → 01_dimensions (DDL + static loads)
            → 03_indexes → 04_etl_pipeline → first refresh_silver()
            → 01_dimensions (derived INSERTs + target tables)
================================================================================
*/

-- ─────────────────────────────────────────────────────────────────────────────
-- DATE DIMENSION
-- ─────────────────────────────────────────────────────────────────────────────
-- Precomputes every temporal attribute once instead of calling EXTRACT() at
-- query time. Range extends well past current data so no backfill is needed.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dim_fecha (
    fecha               DATE PRIMARY KEY,
    anio                INT     NOT NULL,
    mes                 INT     NOT NULL,
    dia                 INT     NOT NULL,
    trimestre           INT     NOT NULL,
    dia_semana          INT     NOT NULL,
    nombre_dia          TEXT,
    nombre_mes          TEXT,
    es_fin_semana       BOOLEAN,
    etiqueta_mes        TEXT,
    etiqueta_trimestre  TEXT,
    anio_mes            INT
);

INSERT INTO dim_fecha
SELECT
    fecha,
    EXTRACT(YEAR    FROM fecha)::INT,
    EXTRACT(MONTH   FROM fecha)::INT,
    EXTRACT(DAY     FROM fecha)::INT,
    EXTRACT(QUARTER FROM fecha)::INT,
    EXTRACT(DOW     FROM fecha)::INT,
    TO_CHAR(fecha, 'TMDay'),
    TO_CHAR(fecha, 'TMMonth'),
    EXTRACT(DOW FROM fecha) IN (0, 6),
    TO_CHAR(fecha, 'TMMon YYYY'),
    'Q' || EXTRACT(QUARTER FROM fecha) || ' ' || EXTRACT(YEAR FROM fecha),
    EXTRACT(YEAR FROM fecha)::INT * 100 + EXTRACT(MONTH FROM fecha)::INT
FROM generate_series('2021-01-01'::DATE, '2035-12-31'::DATE, '1 day') AS fecha;


-- ─────────────────────────────────────────────────────────────────────────────
-- SALES CHANNEL DIMENSION
-- ─────────────────────────────────────────────────────────────────────────────
-- The source system stores the channel as free text on every reservation row.
-- This dimension adds `area_trabajo`, the hierarchy level the business actually
-- reports on, which does not exist anywhere in the source.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dim_canal (
    canal_id      SERIAL PRIMARY KEY,
    nombre_canal  TEXT UNIQUE NOT NULL,
    area_trabajo  TEXT        NOT NULL,
    activo        BOOLEAN     DEFAULT TRUE
);

INSERT INTO dim_canal (nombre_canal, area_trabajo) VALUES
    ('CENTRAL DE RESERVAS',            'Área Reservas'),
    ('PAGINA WEB PROPIA',      'Área Reservas'),
    ('PAGINA ONLINE TERCEROS (OTAS)',  'Área Reservas'),
    ('POR TERCEROS',                   'Área Reservas'),
    ('AGENCIAS',                       'Área Reservas'),
    ('REDES SOCIALES',                 'Área Reservas'),
    ('DIRECCION DE VENTAS',            'Área Reservas'),
    ('OTROS',                          'Área Reservas'),
    ('SOCIOS VIP',                     'Socios'),
    ('EN HOTEL',                       'Hotel'),
    ('WALKING',                        'Hotel'),
    ('RESERVA EN HOTEL',               'Hotel');


-- ─────────────────────────────────────────────────────────────────────────────
-- SALES AGENT DIMENSION
-- ─────────────────────────────────────────────────────────────────────────────
-- Keyed on the source user ID rather than the agent name. Names in the source
-- arrive with inconsistent casing and corrupted accented characters, so the
-- same person appears under several spellings — joining on text would fragment
-- their production across variants. The numeric ID is stable.
--
-- DISTINCT ON keeps the most recent spelling of each agent's name.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dim_asesor (
    asesor_id          SERIAL PRIMARY KEY,
    id_usuario_origen  BIGINT UNIQUE NOT NULL,
    nombre_asesor      TEXT          NOT NULL,
    area_trabajo       TEXT          NOT NULL,
    activo             BOOLEAN       DEFAULT TRUE,
    fecha_creacion     TIMESTAMP     DEFAULT NOW()
);

INSERT INTO dim_asesor (id_usuario_origen, nombre_asesor, area_trabajo)
SELECT DISTINCT ON (b."IDUSUARIO")
    b."IDUSUARIO",
    INITCAP(LOWER(b."ASESOR_RESERVA")),
    CASE
        WHEN b."DESCRIPCION" IN (
            'CENTRAL DE RESERVAS', 'PAGINA WEB PROPIA',
            'PAGINA ONLINE TERCEROS (OTAS)', 'POR TERCEROS',
            'AGENCIAS', 'REDES SOCIALES', 'DIRECCION DE VENTAS', 'OTROS'
        ) THEN 'Área Reservas'
        WHEN b."DESCRIPCION" = 'SOCIOS VIP' THEN 'Socios'
        WHEN b."DESCRIPCION" IN ('EN HOTEL', 'WALKING', 'RESERVA EN HOTEL') THEN 'Hotel'
        ELSE 'Sin clasificar'
    END
FROM bronze_reservas_raw b
WHERE b."IDUSUARIO"       IS NOT NULL
  AND b."IDUSUARIO"       > 0
  AND b."ASESOR_RESERVA"  IS NOT NULL
ORDER BY b."IDUSUARIO",
         TO_DATE(b."FECHA_CREACION", 'DD/MM/YYYY') DESC,
         b."HORA_CREACION" DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- ROOM TYPE DIMENSION
-- ─────────────────────────────────────────────────────────────────────────────
-- The source mixes actual lodging with event products (tents, party packages,
-- lobby rentals, entry tickets) in the same column. Before this dimension every
-- reporting view carried an identical 15-item NOT IN list — impossible to keep
-- in sync. Categorizing once turns that into `WHERE categoria = 'Habitacion'`.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dim_tipo_habitacion (
    tipo_habitacion_id  SERIAL PRIMARY KEY,
    nombre_tipo         TEXT UNIQUE NOT NULL,
    categoria           TEXT        NOT NULL,
    activo              BOOLEAN     DEFAULT TRUE
);

INSERT INTO dim_tipo_habitacion (nombre_tipo, categoria)
SELECT DISTINCT
    tipo_habitacion,
    CASE
        WHEN tipo_habitacion IN (
            'FAMILIAR', 'SUITE', 'SUITE PRESIDENCIAL', 'PRESIDENCIAL',
            'MATRIMONIAL', 'TRIPLE', 'CABAÑA'
        ) THEN 'Habitacion'
        WHEN tipo_habitacion IN ( '~CARPAS')
        THEN 'Carpa'
        ELSE 'Otros'
    END
FROM reservas_detalle
WHERE tipo_habitacion IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────────────────
-- TARGET TABLES
-- ─────────────────────────────────────────────────────────────────────────────
-- Monthly commercial targets, loaded manually by management. Kept as tables
-- rather than constants so historical targets remain auditable.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE metas_hotel_mes (
    hotel_id          INT REFERENCES hoteles(hotel_id),
    anio              INT NOT NULL,
    mes               INT NOT NULL,
    meta_ocupabilidad NUMERIC(12,2),
    meta_produccion   NUMERIC(12,2),
    PRIMARY KEY (hotel_id, anio, mes)
);

CREATE TABLE metas_asesor_mes (
    asesor_id       INT REFERENCES dim_asesor(asesor_id),
    anio            INT NOT NULL,
    mes             INT NOT NULL,
    meta_produccion NUMERIC(12,2),
    PRIMARY KEY (asesor_id, anio, mes)
);
