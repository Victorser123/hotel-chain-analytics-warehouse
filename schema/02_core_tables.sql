/*
================================================================================
 SCHEMA — CORE FACT AND ENTITY TABLES
================================================================================
 Layer:    Silver (normalized)
 Purpose:  Normalized 3NF tables populated by refresh_silver() from the Bronze
           landing zone.
 Run:      First. Dimensions and the ETL pipeline reference these tables.
================================================================================
*/

-- ─────────────────────────────────────────────────────────────────────────────
-- HOTELS
-- ─────────────────────────────────────────────────────────────────────────────
-- Master table enriched with geographic and classification attributes that do
-- not exist in the source system. `cantidad_hab` is the denominator for every
-- occupancy calculation.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE hoteles (
    hotel_id            INT PRIMARY KEY,
    nombre              VARCHAR(200) NOT NULL,
    ciudad              TEXT,
    region              TEXT,
    tipo_hotel          TEXT,
    categoria_estrellas INT,
    cantidad_hab        INT,
    fecha_apertura      DATE,
    fecha_creacion      TIMESTAMP DEFAULT NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- CUSTOMERS
-- ─────────────────────────────────────────────────────────────────────────────
-- Deduplicated on national ID. `pais_origen` is derived at load time: an 8-digit
-- numeric ID indicates a domestic document, anything else a foreign one.
-- Maintained manually: properties are added once at opening, so an automated
-- load would add fragility for no benefit.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE clientes (
    cliente_id            SERIAL PRIMARY KEY,
    dni                   VARCHAR(20) NOT NULL,
    nombre                VARCHAR(200),
    telefono              VARCHAR(50),
    pais_origen           TEXT,
    fecha_primera_reserva DATE,
    fecha_creacion        TIMESTAMP DEFAULT NOW()
);


-- ─────────────────────────────────────────────────────────────────────────────
-- RESERVATIONS (fact header)
-- ─────────────────────────────────────────────────────────────────────────────
-- COMPOSITE PRIMARY KEY (id_reserva_origen, anio_creacion)
--
-- The source system recycles reservation numbers annually: the same IDRESERVA
-- can identify a 2023 booking and an unrelated 2026 booking. Using the source
-- ID alone as PK silently merges them and corrupts historical revenue.
-- The creation year disambiguates them.
--
-- AGGREGATE COLUMNS
--
-- noches_total, total_reserva, fecha_checkin, fecha_checkout, and noches_estadia
-- are precomputed from the detail table after each load. This is deliberate
-- denormalization to prevent fanout: joining header to detail and summing a
-- header column multiplies revenue by the number of nights in the stay.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE reservas (
    id_reserva_origen INT NOT NULL,
    anio_creacion     INT NOT NULL,
    hotel_id          INT NOT NULL REFERENCES hoteles(hotel_id),
    cliente_id        INT NOT NULL REFERENCES clientes(cliente_id),
    fecha_creacion    TIMESTAMP,
    canal             VARCHAR(100),
    sub_canal         VARCHAR(100),
    asesor_reserva    VARCHAR(200),
    id_usuario_asesor BIGINT,
    estado_codigo     INT,
    estado_reserva    VARCHAR(50),
    estado_pago       VARCHAR(50),
    moneda            VARCHAR(20),

    -- Precomputed aggregates (see note above)
    noches_total      INT,
    total_reserva     NUMERIC(12,2),
    fecha_checkin     DATE,
    fecha_checkout    DATE,
    noches_estadia    INT,

    fecha_carga       TIMESTAMP DEFAULT NOW(),

    PRIMARY KEY (id_reserva_origen, anio_creacion)
);


-- ─────────────────────────────────────────────────────────────────────────────
-- RESERVATION DETAIL (fact line)
-- ─────────────────────────────────────────────────────────────────────────────
-- Grain: one row per room, per night. This is the finest level available and
-- the correct source for any occupancy or revenue-by-stay-date metric.
--
-- The natural uniqueness constraint is enforced explicitly. Real collisions
-- exist in the source (same room number, same night, different product) and are
-- resolved deterministically in refresh_silver() rather than dropped.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE reservas_detalle (
    detalle_id        SERIAL PRIMARY KEY,
    id_reserva_origen INT NOT NULL,
    anio_creacion     INT NOT NULL,
    fecha             DATE,
    habitacion_numero INT,
    tipo_habitacion   VARCHAR(50),
    cantidad          INT,
    precio            NUMERIC(10,2),
    total             NUMERIC(10,2),
    pax_adultos       INT,
    pax_ninos         INT,

    -- Denormalized date parts, refreshed after each load for BI convenience
    dia               INT,
    mes               INT,
    año               INT,

    FOREIGN KEY (id_reserva_origen, anio_creacion)
        REFERENCES reservas(id_reserva_origen, anio_creacion),

    CONSTRAINT uq_detalle_natural
        UNIQUE (id_reserva_origen, anio_creacion, fecha, habitacion_numero)
);
