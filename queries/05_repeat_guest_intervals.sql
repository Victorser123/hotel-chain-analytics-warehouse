/*
================================================================================
 REPEAT GUESTS — INTERVAL BETWEEN STAYS
================================================================================
 BUSINESS QUESTION
   Among guests who came back, how far apart are their stays?

 USE CASE
   Sets the timing of the win-back campaign. Contacting a guest at the median
   return interval is worth more than contacting everyone on a fixed calendar.

 TECHNIQUE
   The CTE reduces each booking to (customer, check-in, check-out) from the
   detail rows, because the header is not the right grain for a stay date. The
   self-join on r1.checkin < r2.checkin pairs each stay with every later one,
   and ROW_NUMBER over the customer orders them so consecutive pairs can be
   isolated; COUNT(*) OVER carries the customer's total stay count onto every
   row so the outer query can keep only guests who actually returned.

 WHY THE WINDOW FUNCTIONS ARE IN THE OUTER SELECT
   A window function cannot be filtered in the SELECT that defines it — WHERE is
   evaluated before the window is computed. Computing in a subquery and
   filtering outside is the standard shape for any "top N per group" or
   "consecutive rows" problem.

 NEXT STEP
   LAG(checkin) OVER (PARTITION BY cliente_id ORDER BY checkin) replaces the
   self-join entirely and turns this into a single pass; the self-join is kept
   here because it is what the interval question looks like before window
   functions.
================================================================================
*/

With reservas_detalle1 as (
Select r.cliente_id, r.id_reserva_origen, min(rd.fecha) as checkin, max(rd.fecha) + 1 as checkout
from reservas r 
JOIN
reservas_detalle rd on r.id_reserva_origen = rd.id_reserva_origen
group by r.cliente_id, r.id_reserva_origen
)
 Select * from (
Select r1.cliente_id, r1.id_reserva_origen, r2.checkin, r2.checkout, row_number() over (partition by r1.cliente_id order by checkin) as rownumber1, 
count(*) over(partition by r1.cliente_id) as cant_res 
from reservas_detalle1 r1
join reservas_detalle1 r2 
on r1.cliente_id = r2.cliente_id
and r1.checkin < r2.checkin
 ) t 
 where cant_res > 1
