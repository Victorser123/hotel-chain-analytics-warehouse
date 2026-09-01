/*
================================================================================
 DAILY OCCUPANCY — PIVOTED BY PROPERTY
================================================================================
 BUSINESS QUESTION
   What is today's occupancy rate and revenue at each property, side by side,
   for the current month?

 USE CASE
   Daily operations stand-up. One row per date, one column block per property —
   the shape managers already read in their spreadsheets, so adoption needed no
   retraining.

 WHY PIVOTED
   The long format (one row per hotel per day) is the correct relational shape
   but forces the reader to scan seven rows to compare properties on a given
   date. FILTER (WHERE) collapses it to one row per date and makes the
   comparison a horizontal read.

   Trade-off accepted deliberately: adding a property means adding a column
   block. At seven properties that is manageable; at fifty, long format plus a
   BI-layer pivot would be the right call.

 OCCUPANCY DENOMINATOR
   hoteles.cantidad_hab is the room inventory. MAX() inside the FILTER is an
   aggregate-safe way to carry a constant dimension attribute through a GROUP BY
   without adding it to the grouping key.

 KNOWN LIMITATIONS, LEFT IN DELIBERATELY
   - The excluded IDs are internal cost centres rather than properties open to
     guests. A hoteles.es_operativo flag would be the dimension-driven version
     of this filter, consistent with how room types are handled.
   - CURRENT_DATE resolves in the database time zone. On a UTC instance the
     report rolls over five hours early for a Lima audience;
     (NOW() AT TIME ZONE 'America/Lima')::DATE fixes it.
================================================================================
*/

SELECT
    rd.fecha,
    SUM(rd.total) FILTER (WHERE r.hotel_id = 41) AS h41_ingresos,
    COUNT(*) FILTER (WHERE r.hotel_id = 41) AS h41_ocup,
    ROUND(
        (
            COUNT(*) FILTER (WHERE r.hotel_id = 41)
        )::numeric * 100
        /
        MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 41),
        2
    ) AS h41_percentage_ocu,


    SUM(rd.total) FILTER (WHERE r.hotel_id = 60) AS h60_ingresos,
    COUNT(*) FILTER (WHERE r.hotel_id = 60) AS h60_ocup,
    ROUND(
        (
            COUNT(*) FILTER (WHERE r.hotel_id = 60)
        )::numeric * 100
        /
        MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 60),
        2
    ) AS h60_percentage_ocu,


    SUM(rd.total) FILTER (WHERE r.hotel_id = 61) AS h61_ingresos,
    COUNT(*) FILTER (WHERE r.hotel_id = 61) AS h61_ocup,
    ROUND(
        (
            COUNT(*) FILTER (WHERE r.hotel_id = 61)
        )::numeric * 100
        /
        MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 61),
        2
    ) AS h61_percentage_ocu,

    SUM(rd.total) FILTER (WHERE r.hotel_id = 64) AS h64_ingresos,
    COUNT(*) FILTER (WHERE r.hotel_id = 64) AS h64_ocup,
    ROUND(
        (
            COUNT(*) FILTER (WHERE r.hotel_id = 64)
        )::numeric * 100
        /
        MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 64),
        2
    ) AS h64_percentage_ocu,

    SUM(rd.total) FILTER (WHERE r.hotel_id = 69) AS h69_ingresos,
    COUNT(*) FILTER (WHERE r.hotel_id = 69) AS h69_ocup,
    ROUND(
        (
            COUNT(*) FILTER (WHERE r.hotel_id = 69)
        )::numeric * 100
        /
        MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 69),
        2
    ) AS h69_percentage_ocu,

    SUM(rd.total) FILTER (WHERE r.hotel_id = 71) AS h71_ingresos,
    COUNT(*) FILTER (WHERE r.hotel_id = 71) AS h71_ocup,
    ROUND(
        (
            COUNT(*) FILTER (WHERE r.hotel_id = 71)
        )::numeric * 100
        /
        MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 71),
        2
    ) AS h71_percentage_ocu,

    SUM(rd.total) FILTER (WHERE r.hotel_id = 86) AS h86_ingresos,
    COUNT(*) FILTER (WHERE r.hotel_id = 86) AS h86_ocup,
    ROUND(
        (
            COUNT(*) FILTER (WHERE r.hotel_id = 86)
        )::numeric * 100
        /
        MAX(h.cantidad_hab) FILTER (WHERE r.hotel_id = 86),
        2
    ) AS h86_percentage_ocu

FROM reservas r
JOIN reservas_detalle rd
    ON r.id_reserva_origen = rd.id_reserva_origen
JOIN hoteles h
    ON r.hotel_id = h.hotel_id
WHERE r.hotel_id NOT IN (29, 999, 66)
  AND EXTRACT(YEAR FROM rd.fecha) = EXTRACT(YEAR FROM CURRENT_DATE)
  AND EXTRACT(MONTH FROM rd.fecha) = EXTRACT(MONTH FROM CURRENT_DATE)
GROUP BY rd.fecha
ORDER BY rd.fecha;
   


------------------------------------------------------------------------------------------------------------------------------
--CONSOLIDADO GESTION INTEGRAL - VENTA CON CARPA;
