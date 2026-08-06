/*
================================================================
AGENT PERFORMANCE — RANKING AND PEER COMPARISON
================================================================
AUTHOR: Victor Sernaque

BUSINESS QUESTION:
  Beyond a flat leaderboard, how does each agent compare against
  the peers they should actually be compared against?

USE CASE:
  Performance reviews and commission discussions. A raw ranking
  penalises agents in smaller teams and rewards those sitting on
  high-volume channels. Ranking within work area, plus the gap to
  the peer average, makes the comparison defensible in a review.

TECHNIQUES:
  - ROW_NUMBER over the full population and within each work area
  - AVG OVER (PARTITION BY area) to carry the peer average onto
    every row without a second aggregation and a self-join
  - NTILE(10) for decile banding, which is stable as headcount changes
    in a way that fixed thresholds are not
  - LAG to show the gap to the next agent up, turning a rank into an
    actionable target

WHY A CTE:
  Window functions cannot be filtered in the same SELECT that defines
  them — WHERE is evaluated before the window is computed. Aggregating
  first in a CTE, then ranking, then filtering in the outer query is
  the standard three-step shape for any "top N per group" problem.

JOIN KEY:
  On id_usuario_origen, not the agent name. Names arrive from the
  source system with inconsistent accent encoding and would fragment
  a single person into several rows.
================================================================
*/

WITH agent_totals AS (
    SELECT
        da.asesor_id,
        da.nombre_asesor,
        da.area_trabajo,
        COUNT(DISTINCT r.id_reserva_origen) AS reservas,
        COUNT(DISTINCT r.cliente_id)        AS clientes_atendidos,
        COUNT(DISTINCT r.hotel_id)          AS hoteles_atendidos,
        SUM(r.total_reserva)                AS ingresos,
        ROUND(AVG(r.total_reserva), 2)      AS ticket_promedio
    FROM reservas r
    JOIN dim_asesor da
        ON da.id_usuario_origen = r.id_usuario_asesor
    JOIN dim_fecha df
        ON df.fecha = DATE(r.fecha_creacion)
    WHERE df.anio = 2025
      AND da.activo = TRUE
      AND NOT (r.estado_pago = 'No pagado' AND r.estado_reserva = 'Reservado')
    GROUP BY da.asesor_id, da.nombre_asesor, da.area_trabajo
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY ingresos DESC)                        AS rank_global,
        ROW_NUMBER() OVER (PARTITION BY area_trabajo ORDER BY ingresos DESC) AS rank_area,
        NTILE(10)    OVER (ORDER BY ingresos DESC)                        AS decil,
        ROUND(AVG(ingresos) OVER (PARTITION BY area_trabajo), 2)          AS promedio_area,
        ROUND(
            100.0 * ingresos / SUM(ingresos) OVER (PARTITION BY area_trabajo), 2
        )                                                                 AS pct_del_area,
        LAG(ingresos) OVER (PARTITION BY area_trabajo ORDER BY ingresos DESC)
                                                                          AS ingresos_puesto_superior
    FROM agent_totals
)
SELECT
    nombre_asesor,
    area_trabajo,
    cant_reservas,
    n_clientes,
    cant_ing,
    ticket_promedio,
    rank_area,
    rank_global,
    promedio_area,
    ROUND(ingresos - promedio_area, 2) AS diferencia_vs_promedio,
    pct_del_area,
    ROUND(ingresos_puesto_superior - ingresos, 2) AS brecha_al_puesto_superior,
    CASE
        WHEN decil = 1  THEN 'Top 10%'
        WHEN decil <= 2 THEN 'Top 20%'
        WHEN decil <= 5 THEN 'Sobre la mediana'
        WHEN decil <= 8 THEN 'Bajo la mediana'
        ELSE                 'Último 20%'
    END AS banda
FROM ranked
ORDER BY area_trabajo, rank_area;
