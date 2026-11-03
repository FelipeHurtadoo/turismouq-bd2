-- =====================================================================
-- TurismoUQ · 16a_concurrencia_sesion_A.sql
-- Ejecutar como: TURISMO_UQ, en la VENTANA A
--
-- Versión MANUAL (en vivo) del experimento de 16_concurrencia.sql.
-- Se necesitan DOS sesiones reales:
--   · SQL Developer: abra este archivo y 16b en hojas NO COMPARTIDAS
--     (Ctrl+Shift+N, o el botón "Unshared SQL Worksheet"). Dos hojas
--     normales de la misma conexión comparten sesión y NO sirven.
--   · sqlplus: dos terminales.
-- Opcional: una tercera hoja con 16c_concurrencia_monitor.sql para ver el
-- bloqueo desde afuera mientras ocurre.
--
-- NO ejecute el archivo completo: ejecute UN PASO a la vez (seleccione el
-- bloque y F5 / Ctrl+Enter), alternando con la ventana B como se indica.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

-- ---------------------------------------------------------------------
-- PASO A0 · limpieza de corridas anteriores del experimento manual
-- ---------------------------------------------------------------------
DELETE FROM reserva WHERE observaciones LIKE 'DEMO_E3 conc%';
COMMIT;

-- =====================================================================
-- ESCENARIO 1 · ANTES (sin bloqueo)
-- =====================================================================

-- ---------------------------------------------------------------------
-- PASO A1 · reservar SIN bloqueo y SIN COMMIT
-- ---------------------------------------------------------------------
DECLARE
   v_habs  pkg_turismo.t_lista_habitaciones;
   v_aloj  NUMBER;
   v_fecha DATE;
   v_cli   NUMBER;
   v_id    NUMBER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_cli FROM cliente;
   pkg_turismo.sp_crear_reserva(v_cli, v_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id);
   UPDATE reserva SET observaciones = 'DEMO_E3 conc manual A' WHERE id_reserva = v_id;
   DBMS_OUTPUT.PUT_LINE('[A ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] reserva ' || v_id ||
      ' · habitación ' || v_habs(1) || ' · ' || TO_CHAR(v_fecha, 'YYYY-MM-DD') ||
      ' (2 noches) · SIN COMMIT');
   DBMS_OUTPUT.PUT_LINE('>>> Ahora ejecute el PASO B1 en la ventana B.');
END;
/

-- ---------------------------------------------------------------------
-- PASO A2 · (después de que B1 terminó) confirmar y ver el resultado
-- ---------------------------------------------------------------------
COMMIT;

SELECT r.id_reserva, rh.id_habitacion, r.fecha_checkin, r.fecha_checkout, r.observaciones
  FROM reserva r
  JOIN reserva_habitacion rh ON rh.id_reserva = r.id_reserva
 WHERE r.observaciones LIKE 'DEMO_E3 conc manual%'
 ORDER BY r.id_reserva;
-- Esperado: DOS filas, misma habitación, mismas fechas -> doble reserva.

-- ---------------------------------------------------------------------
-- PASO A3 · deshacer la doble reserva antes del escenario 2
-- ---------------------------------------------------------------------
DELETE FROM reserva WHERE observaciones LIKE 'DEMO_E3 conc%';
COMMIT;

-- =====================================================================
-- ESCENARIO 2 · DESPUÉS (con SELECT ... FOR UPDATE)
-- =====================================================================

-- ---------------------------------------------------------------------
-- PASO A4 · reservar CON bloqueo de la habitación y SIN COMMIT
-- ---------------------------------------------------------------------
DECLARE
   v_habs  pkg_turismo.t_lista_habitaciones;
   v_aloj  NUMBER;
   v_fecha DATE;
   v_cli   NUMBER;
   v_id    NUMBER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_cli FROM cliente;
   pkg_transacciones.sp_crear_reserva_segura(v_cli, v_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id);
   UPDATE reserva SET observaciones = 'DEMO_E3 conc manual A' WHERE id_reserva = v_id;
   DBMS_OUTPUT.PUT_LINE('[A ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] FOR UPDATE sobre la habitación ' ||
      v_habs(1) || ' + reserva ' || v_id || ' · SIN COMMIT');
   DBMS_OUTPUT.PUT_LINE('>>> Ahora ejecute el PASO B2 en la ventana B: se va a quedar esperando.');
   DBMS_OUTPUT.PUT_LINE('>>> (Opcional) mire 16c_concurrencia_monitor.sql en una tercera ventana.');
END;
/

-- ---------------------------------------------------------------------
-- PASO A5 · liberar el bloqueo. En ese instante B continúa y es rechazada.
-- ---------------------------------------------------------------------
COMMIT;

SELECT r.id_reserva, rh.id_habitacion, r.fecha_checkin, r.fecha_checkout, r.observaciones
  FROM reserva r
  JOIN reserva_habitacion rh ON rh.id_reserva = r.id_reserva
 WHERE r.observaciones LIKE 'DEMO_E3 conc manual%'
 ORDER BY r.id_reserva;
-- Esperado: UNA sola fila.

-- ---------------------------------------------------------------------
-- PASO A6 · limpieza final
-- ---------------------------------------------------------------------
DELETE FROM reserva WHERE observaciones LIKE 'DEMO_E3 conc%';
COMMIT;
