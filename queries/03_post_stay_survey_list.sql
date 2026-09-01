/*
================================================================================
 POST-STAY SURVEY LIST
================================================================================
 BUSINESS QUESTION
   Which guests checked out on the target days, and what is a usable mobile
   number for each of them?

 USE CASE
   Feeds the post-stay satisfaction survey. The output is a two-column list the
   messaging tool consumes directly, which is why it is this narrow.

 TECHNIQUES
   - DISTINCT ON (dni) keeps one row per guest, ordered so the highest-value
     stay wins when someone has more than one booking in the window
   - A regex normalises phone numbers to E.164 for Peru and labels the rest
     invalid rather than sending malformed numbers to the gateway
   - split_part() extracts the given names from a single full-name column;
     the source stores surnames first, so the third and fourth tokens are the
     first names

 NOTE
   The checkout days are hardcoded because the survey runs on a fixed cadence.
   Parameterise them when this moves to a scheduler.
================================================================================
*/

with real as (
SELECT DISTINCT ON (c.dni)
    c.cliente_id,
    c.dni,
    c.nombre,
    a.noches_total,
    a.total_reserva,
    split_part(c.nombre, ' ', 3) || ' ' || split_part(c.nombre, ' ', 4) AS nombres,
    CASE
    WHEN c.telefono ~ '^[0-9]{9}$' THEN '51' || c.telefono
    WHEN c.telefono ~ '^51[0-9]{9}$' THEN c.telefono
    ELSE 'No valido'
END AS telefono_limpio,
    a.check_in,
    a.check_out
FROM clientes c
JOIN (
    SELECT
        r.id_reserva_origen,
        r.cliente_id,
        r.noches_total,
        r.total_reserva,
        r.fecha_checkin as check_in,
        r.fecha_checkout as check_out
    FROM reservas r
    WHERE r.hotel_id NOT IN (29,999,66)
    AND EXTRACT(YEAR FROM fecha_checkout) = EXTRACT(YEAR FROM CURRENT_DATE)
    AND EXTRACT(MONTH FROM fecha_checkout) = EXTRACT(MONTH FROM CURRENT_DATE)
    AND EXTRACT(DAY FROM fecha_checkout) in (13,14)
) a
ON a.cliente_id = c.cliente_id
ORDER BY c.dni, a.total_reserva desc , a.check_in )
select telefono_limpio as Teléfono , nombres as viajero --, CHECK_OUT 
from real
where telefono_limpio <> 'No valido'
