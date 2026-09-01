/*
================================================================================
 PROPERTY AVERAGE RATE VS THE NETWORK
================================================================================
 BUSINESS QUESTION
   How does each property's average revenue per room-night compare against the
   chain as a whole?

 USE CASE
   Rate positioning. A property below the network average is either
   under-priced or selling a weaker mix; either way it is the first place to
   look before touching the rate card.

 TECHNIQUE
   The network average is an uncorrelated scalar subquery, evaluated once and
   reused. Expressing it as a window function over the whole table would work
   too, but the subquery makes the denominator explicit — it is the average
   across every room-night in the chain, not across the seven property averages,
   and those two numbers differ whenever properties sell different volumes.

 GRAIN
   rd.total is the room-night amount, so AVG() here is the average nightly rate.
   Averaging the header total instead would return the average booking value,
   which is a different question.
================================================================================
*/

select
h.nombre,
round(avg(rd.total),2) as ingreso_promedio_noche,
round((
  Select avg(total) from reservas_detalle
),2) as promedio_red,
round(avg(rd.total)*100/(
  Select avg(total) from reservas_detalle
),2) as pct_vs_red
from reservas_detalle rd  
join reservas r on rd.id_reserva_origen = r.id_reserva_origen
join hoteles h on r.hotel_id = h.hotel_id
group by h.nombre
