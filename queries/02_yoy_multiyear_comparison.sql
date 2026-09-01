/*
================================================================================
 MULTI-YEAR REVENUE COMPARISON
================================================================================
 BUSINESS QUESTION
   How does each property's performance in a given month compare against the
   same month in prior years?

 USE CASE
   Board reporting and budget defence. Seasonality in this chain is pronounced,
   so a month-over-month number is meaningless; like month against like month is
   the only honest comparison.

 TECHNIQUE
   One conditional aggregate per year, producing a wide row per property. The
   growth rate is NULLIF-guarded because a property that opened mid-series has a
   zero prior-year base.

 MEASUREMENT FRAME
   Stay date. This is a revenue-realisation view, not a sales-attribution view.

 FIX APPLIED
   The join to reservas_detalle carried only id_reserva_origen. Because the
   source recycles booking IDs annually, every recycled booking was
   cross-multiplied against the detail rows of its namesakes in other years —
   inflating exactly the year-over-year revenue this query exists to measure.
   Now joins on the full composite key.

 PARAMETER
   The target month is hardcoded below. In production this runs from the BI
   layer with the month passed as a parameter.
================================================================================
*/


    SUM(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2022 THEN rdh.total ELSE 0 END) AS sum_2022,
    COUNT(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2022 THEN 1 END) AS count_2022,

    SUM(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2023 THEN rdh.total ELSE 0 END) AS sum_2023,
    COUNT(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2023 THEN 1 END) AS count_2023,

    SUM(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2024 THEN rdh.total ELSE 0 END) AS sum_2024,
    COUNT(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2024 THEN 1 END) AS count_2024,

    SUM(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2025 THEN rdh.total ELSE 0 END) AS sum_2025,
    COUNT(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2025 THEN 1 END) AS count_2025,

    SUM(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2026 THEN rdh.total ELSE 0 END) AS sum_2026,
    COUNT(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2026 THEN 1 END) AS count_2026,

    ROUND((SUM(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2026 THEN rdh.total ELSE 0 END)
     / 
     nullif(
        SUM(CASE WHEN EXTRACT(YEAR FROM rdh.fecha) = 2025 
        THEN rdh.total ELSE 0 END)
        ,0)
        -1)*100,2) AS Comparativo_Yoy_perc

FROM reservas r
JOIN reservas_detalle rdh
    ON  r.id_reserva_origen = rdh.id_reserva_origen
    AND r.anio_creacion     = rdh.anio_creacion
WHERE EXTRACT(YEAR FROM rdh.fecha) >= 2022
  and not (r.estado_pago = 'No pagado' and r.estado_reserva = 'Reservado')
  AND EXTRACT(MONTH FROM rdh.fecha) = 6
GROUP BY r.hotel_id
ORDER BY r.hotel_id;
