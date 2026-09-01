/*
================================================================================
 SILVER — CONFORMED DIMENSIONS
================================================================================
 Layer: Silver
 Run:   After 01_core_tables.sql. DDL and static loads only.

 The two derived dimensions read from loaded fact data, so their INSERTs live
 in 05_derived_dimensions.sql and run after the first refresh_silver(). Keeping
 DDL and derived loads in one file made the bootstrap unrunnable as a script:
 the file has to execute both before and after the pipeline, and the second pass
 aborts on the CREATE TABLEs it already ran.

 dim_fecha and dim_canal are static and load immediately.

 NOTE — MISSING STATEMENT TERMINATORS
   Several CREATE TABLE statements in the working scripts had no trailing
   semicolon. The Supabase SQL editor runs a highlighted statement at a time and
   tolerates that; a file fed to psql does not, and the script aborted at the
   first INSERT following an unterminated CREATE. Terminators added.
 dim_asesor and dim_tipo_habitacion derive from the fact data.
================================================================================
*/

-- ─────────────────────────────────────────────────────────────────────────────
-- DATE DIMENSION
-- ─────────────────────────────────────────────────────────────────────────────
-- Precomputes every temporal attribute once instead of calling EXTRACT() at
-- query time. The range runs well past current data so no backfill is needed.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dim_fecha (
    fecha date primary key,
    anio int not null,
    mes int not null,
    dia int not null,
    trimestre int not null,
    dia_semana int not null,
    nombre_dia text,
    nombre_mes text,
    es_fin_semana Boolean,
    etiqueta_mes text,
    etiqueta_trimestre text,
    anio_mes int
);

insert into dim_fecha 
select
    fecha,
    Extract (YEAR from fecha)::INT,
    Extract (MONTH from fecha)::INT,
    Extract (DAY from fecha)::INT,
    Extract (QUARTER from fecha)::INT,
    Extract (DOW from fecha)::INT,
    TO_CHAR(fecha, 'TMDay'),
    TO_CHAR(fecha, 'TMMonth'),
    EXTRACT(DOW FROM fecha) in (0,6),
    TO_CHAR(fecha, 'TMMon YYYY'),
    'Q' || EXTRACT(QUARTER FROM fecha) || ' ' || EXTRACT(YEAR FROM fecha),
    EXTRACT(year FROM fecha)::INT*100 +  EXTRACT(MONTH FROM fecha)::INT
    FROM
    generate_series('2021-01-01'::DATE,'2035-12-31'::DATE, '1 day') as fecha;

-- ─────────────────────────────────────────────────────────────────────────────
-- SALES CHANNEL DIMENSION
-- ─────────────────────────────────────────────────────────────────────────────
-- The source stores the channel as free text on every reservation row. This
-- dimension adds area_trabajo, the hierarchy level the business reports on,
-- which exists nowhere in the source.
-- ─────────────────────────────────────────────────────────────────────────────

create table dim_canal(
    canal_id serial primary key,
    nombre_canal text unique not null,
    area_trabajo text not null,
    activo boolean default true
);

insert into dim_canal (nombre_canal, area_trabajo) values 
('CENTRAL DE RESERVAS', 'Área Reservas'),
('PAGINA WEB PROPIA', 'Área Reservas'),
('PAGINA ONLINE TERCEROS (OTAS)', 'Área Reservas'),
('POR TERCEROS', 'Área Reservas'),
('AGENCIAS', 'Área Reservas'),
('REDES SOCIALES', 'Área Reservas'),
('DIRECCION DE VENTAS', 'Área Reservas'),
('OTROS', 'Área Reservas'),
('SOCIOS VIP', 'Socios'),
('EN HOTEL', 'Hotel'),
('WALKING', 'Hotel'),
('RESERVA EN HOTEL', 'Hotel');

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
-- Run after the first refresh_silver().
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE dim_asesor (
    asesor_id           SERIAL PRIMARY KEY,
    id_usuario_origen   BIGINT UNIQUE NOT NULL,
    nombre_asesor       TEXT NOT NULL,
    area_trabajo        TEXT NOT NULL,
    activo              BOOLEAN DEFAULT TRUE,
    fecha_creacion      TIMESTAMP DEFAULT NOW()
);

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

CREATE TABLE dim_tipo_habitacion (
    tipo_habitacion_id  SERIAL PRIMARY KEY,
    nombre_tipo         TEXT UNIQUE NOT NULL,
    categoria           TEXT NOT NULL,
    activo              BOOLEAN DEFAULT TRUE
);

-- ─────────────────────────────────────────────────────────────────────────────
-- TARGET TABLES
-- ─────────────────────────────────────────────────────────────────────────────
-- Monthly commercial targets, loaded by management. Kept as tables rather than
-- constants so historical targets stay auditable.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE metas_hotel_mes (
    hotel_id INT REFERENCES hoteles(hotel_id),
    anio INT NOT NULL,
    mes INT NOT NULL,
    meta_ocupabilidad NUMERIC(12,2),
    meta_produccion NUMERIC(12,2),
    PRIMARY KEY (hotel_id, anio, mes)
);

CREATE TABLE metas_asesor_mes (
    asesor_id        INT REFERENCES dim_asesor(asesor_id),
    anio             INT NOT NULL,
    mes              INT NOT NULL,
    meta_produccion  NUMERIC(12,2),
    PRIMARY KEY (asesor_id, anio, mes)
);
