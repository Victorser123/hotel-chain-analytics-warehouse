/*
================================================================================
 OPS — GRANTS AND ROW LEVEL SECURITY
================================================================================
 Run: Last, after every object exists.

 NOTE: this file has no counterpart in the working scripts — the warehouse has
 been running on Supabase defaults. It is the access model the pipeline implies,
 written down. Review each grant against the real roles before applying.

 THREAT MODEL
   anon           unauthenticated — must reach nothing
   authenticated  a signed-in analyst — reads the reporting layer only
   service_role   the Excel loader and the BI account — runs the pipeline

 The pipeline functions are exposed as RPC endpoints over PostgREST, so they
 need SECURITY DEFINER with a pinned search_path: they then run with the
 owner's rights on tables the caller cannot touch directly, and cannot be
 hijacked by a caller who puts a malicious schema earlier in their path. Apply
 that to the three functions when you run this.
================================================================================
*/

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon, authenticated;

-- ── Reporting layer: read-only for signed-in analysts ─────────────────────
GRANT SELECT ON
    v_ocupabilidad_total,
    v_ventas_ocupabilidad_reservas,
    v_ventas_con_carpa_total,
    v_ocupabilidad_pago_socios,
    v_produccion,
    v_ranking_asesores,
    v_produccion_asesor,
    v_ocupacion_asesor_hotel,
    v_health_check,
    v_carga_reciente,
    v_carga_stats,
    mv_cliente_metricas
TO authenticated;

GRANT SELECT ON dim_fecha, dim_canal, dim_asesor, dim_tipo_habitacion, hoteles
TO authenticated;

-- ── Pipeline and PII: service role only ───────────────────────────────────
-- fact_reservas carries dni, nombre and telefono, so it is deliberately absent
-- from the grant above. clientes is never exposed at all: customer behaviour
-- reaches the reporting layer through mv_cliente_metricas, which carries no
-- identifying column.
GRANT SELECT ON fact_reservas TO service_role;
GRANT EXECUTE ON FUNCTION delete_bronze_rango(DATE, DATE) TO service_role;
GRANT EXECUTE ON FUNCTION refresh_silver(NUMERIC)         TO service_role;
GRANT EXECUTE ON FUNCTION refresh_gold()                  TO service_role;
GRANT ALL ON bronze_reservas_raw                          TO service_role;

-- ── RLS on the base tables ────────────────────────────────────────────────
-- Enabled with no permissive policy: the base tables stay unreachable through
-- the API even if a GRANT is added by mistake later. service_role bypasses RLS
-- by design, which is what lets the loader work.
ALTER TABLE bronze_reservas_raw ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservas            ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservas_detalle    ENABLE ROW LEVEL SECURITY;
ALTER TABLE clientes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE etl_log             ENABLE ROW LEVEL SECURITY;
ALTER TABLE metas_hotel_mes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE metas_asesor_mes    ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE clientes IS
    'Contains PII (DNI, phone). Never granted to authenticated; expose only via mv_cliente_metricas.';

