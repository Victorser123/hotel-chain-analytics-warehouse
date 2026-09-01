/*
================================================================================
 SILVER — CORE FACT AND ENTITY TABLES
================================================================================
 Layer: Silver (normalised 3NF)
 Run:   After sql/bronze/.

 CONSOLIDATED DDL
 ----------------
 These tables grew through ALTER TABLE as the model developed. The definitions
 below fold every later ALTER back into the CREATE, so a fresh database reaches
 the current shape in one statement instead of replaying the history:

   reservas          + fecha_checkin, fecha_checkout, noches_estadia
   reservas_detalle  + dia, mes, "año"
   clientes          + pais_origen
   hoteles           + ciudad, region, tipo_hotel, categoria_estrellas,
                       fecha_apertura, cantidad_hab

 hoteles and clientes predate the project and had no CREATE statement on record;
 their columns are taken from the ALTERs that extended them and from every
 reference in the pipeline and the reporting layer. Verify with:

   SELECT table_name, column_name, data_type
   FROM information_schema.columns
   WHERE table_name IN ('hoteles','clientes')
   ORDER BY table_name, ordinal_position;
================================================================================
*/

-- ─────────────────────────────────────────────────────────────────────────────
-- HOTELS
-- ─────────────────────────────────────────────────────────────────────────────
-- Enriched with geography and classification that do not exist in the source
-- system. cantidad_hab is the denominator of every occupancy calculation.
-- Maintained by hand: a property is added once, at opening.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS hoteles (
    hotel_id            INT PRIMARY KEY,
    nombre              VARCHAR(200) NOT NULL,
    ciudad              TEXT,
    region              TEXT,
    tipo_hotel          TEXT,
    categoria_estrellas INT,
    cantidad_hab        INT,
    fecha_apertura      DATE
);


-- ─────────────────────────────────────────────────────────────────────────────
-- CUSTOMERS
-- ─────────────────────────────────────────────────────────────────────────────
-- Deduplicated on national ID. pais_origen is derived at load time: an 8-digit
-- numeric document is domestic, anything else foreign.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS clientes (
    cliente_id            SERIAL PRIMARY KEY,
    dni                   VARCHAR(20) NOT NULL,
    nombre                VARCHAR(200),
    telefono              VARCHAR(50),
    fecha_primera_reserva DATE,
    pais_origen           TEXT
);


-- ─────────────────────────────────────────────────────────────────────────────
-- RESERVATIONS (fact header)
-- ─────────────────────────────────────────────────────────────────────────────
-- COMPOSITE PRIMARY KEY (id_reserva_origen, anio_creacion)
--
-- The source PMS recycles reservation numbers annually: the same IDRESERVA
-- identifies an unrelated booking in each year. Using it alone as the key
-- silently merges them and corrupts historical revenue.
--
-- Any join from this table to reservas_detalle must carry BOTH columns. A join
-- on id_reserva_origen alone cross-multiplies every recycled booking against
-- the detail rows of its namesakes in other years and inflates revenue.
--
-- AGGREGATE COLUMNS
--
-- noches_total, total_reserva, fecha_checkin, fecha_checkout and noches_estadia
-- are precomputed from the detail rows after each load. Deliberate
-- denormalisation against fan-out: it lets header-grain reports answer revenue
-- questions without joining the line table at all.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS reservas (
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

    -- Precomputed from reservas_detalle by refresh_silver()
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
-- Grain: one row per room, per night. The finest level available and the
-- correct source for any occupancy or revenue-by-stay-date metric.
--
-- The natural uniqueness constraint is enforced explicitly. Real collisions
-- exist in the source — one room billed twice on the same night under two
-- different SKUs — and are resolved deterministically in refresh_silver()
-- rather than dropped.
--
-- dia / mes / "año" are denormalised date parts, refreshed after each load for
-- BI tools with limited pushdown.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS reservas_detalle (
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
    dia               INT,
    mes               INT,
    "año"             INT,

    FOREIGN KEY (id_reserva_origen, anio_creacion)
        REFERENCES reservas(id_reserva_origen, anio_creacion),

    CONSTRAINT uq_detalle_natural
        UNIQUE (id_reserva_origen, anio_creacion, fecha, habitacion_numero)
);

