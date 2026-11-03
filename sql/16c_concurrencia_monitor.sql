-- =====================================================================
-- TurismoUQ · 16c_concurrencia_monitor.sql
-- Ejecutar como: TURISMO_UQ, en una TERCERA ventana, mientras la
-- ventana B está esperando (entre los pasos A4/B2 y A5).
--
-- Muestra el bloqueo "desde afuera": quién espera, a quién, por cuál fila.
-- =====================================================================

PROMPT === Sesiones del esquema que están esperando un bloqueo ===
SELECT s.sid,
       s.serial#,
       s.blocking_session    AS bloqueada_por,
       s.event,
       s.seconds_in_wait     AS segundos,
       o.object_name         AS tabla,
       s.row_wait_row#       AS fila_en_bloque
  FROM v$session s
  LEFT JOIN user_objects o ON o.object_id = s.row_wait_obj#
 WHERE s.username = 'TURISMO_UQ'
   AND s.blocking_session IS NOT NULL;
-- Esperado: la sesión B, bloqueada_por = SID de A,
-- event = 'enq: TX - row lock contention', tabla = HABITACION.

PROMPT === Bloqueos TX: quién bloquea (BLOCK=1) y quién solicita (REQUEST=6) ===
SELECT l.sid, l.type, l.lmode, l.request, l.block, l.ctime AS segundos
  FROM v$lock l
  JOIN v$session s ON s.sid = l.sid
 WHERE s.username = 'TURISMO_UQ'
   AND l.type = 'TX'
 ORDER BY l.block DESC, l.sid;

PROMPT === Objetos con bloqueo de tabla (TM) por sesión ===
SELECT lo.session_id AS sid, o.object_name,
       DECODE(lo.locked_mode, 2, 'ROW SHARE (SS)', 3, 'ROW EXCLUSIVE (SX)',
                              4, 'SHARE', 5, 'SSX', 6, 'EXCLUSIVE', lo.locked_mode) AS modo
  FROM v$locked_object lo
  JOIN user_objects o ON o.object_id = lo.object_id
 ORDER BY lo.session_id, o.object_name;
