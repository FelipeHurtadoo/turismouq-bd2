-- =====================================================================
-- TurismoUQ · 16_concurrencia.sql
-- Ejecutar como: TURISMO_UQ   (después de 13 y 14)
--
-- Entrega 3 · Experimento de concurrencia: dos sesiones intentan reservar
-- la MISMA habitación en las MISMAS fechas al mismo tiempo.
--
-- Cómo hay dos sesiones dentro de un solo script: la SESIÓN A es esta
-- (la de SQL Developer / sqlplus). La SESIÓN B es un job de DBMS_SCHEDULER,
-- que Oracle ejecuta en OTRA sesión, con su propia transacción. B imprime
-- con DBMS_OUTPUT y esa salida queda guardada en
-- USER_SCHEDULER_JOB_RUN_DETAILS.OUTPUT, de donde A la lee al final.
-- Así el experimento es reproducible y queda evidencia con marcas de tiempo.
-- (La versión manual con dos ventanas está en 16a / 16b / 16c.)
--
--   Escenario 1 · ANTES  : sin bloqueo (pkg_turismo.sp_crear_reserva).
--                          Resultado esperado: DOBLE RESERVA (anomalía).
--   Escenario 2 · DESPUÉS: con SELECT ... FOR UPDATE
--                          (pkg_transacciones.sp_crear_reserva_segura).
--                          Resultado esperado: B queda BLOQUEADA hasta el
--                          COMMIT de A y después recibe -20002.
--   Escenario 3 · Variantes NOWAIT y WAIT n: B no se queda esperando.
--
-- Cada escenario tarda unos 10-15 segundos (hay esperas a propósito).
-- Al final borra las reservas de prueba: el histórico queda intacto.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO OFF
SET LINESIZE 200

PROMPT
PROMPT ############ 0. Preparación ############

DELETE FROM reserva WHERE observaciones LIKE 'DEMO_E3 conc%';
COMMIT;

BEGIN
   FOR j IN (SELECT job_name FROM user_scheduler_jobs WHERE job_name LIKE 'EXP_CONC%') LOOP
      DBMS_SCHEDULER.DROP_JOB(j.job_name, force => TRUE);
   END LOOP;
END;
/

-- ---------------------------------------------------------------------
-- Utilidades compartidas por los tres escenarios. Se declaran como un
-- paquete temporal para no repetirlas en cada bloque; se borra al final.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PACKAGE exp_concurrencia AUTHID CURRENT_USER AS
   FUNCTION ahora RETURN VARCHAR2;
   -- Crea y lanza el job "sesión B". p_llamada es la invocación PL/SQL que
   -- intentará la reserva; el job espera p_retardo segundos antes de
   -- intentarlo para que A alcance a tomar la habitación primero.
   PROCEDURE lanzar_sesion_b(p_job VARCHAR2, p_llamada VARCHAR2,
                             p_hab NUMBER, p_aloj NUMBER, p_fecha DATE,
                             p_retardo NUMBER DEFAULT 3);
   -- Espera a que el job termine e imprime lo que la sesión B escribió.
   PROCEDURE mostrar_sesion_b(p_job VARCHAR2, p_desde TIMESTAMP WITH TIME ZONE);
   -- Imprime quién bloquea a quién en este momento (V$SESSION).
   PROCEDURE mostrar_bloqueos;
   -- Cuántas reservas activas tiene la habitación en ese rango.
   FUNCTION reservas_activas(p_hab NUMBER, p_fecha DATE, p_noches NUMBER) RETURN NUMBER;
END exp_concurrencia;
/

CREATE OR REPLACE PACKAGE BODY exp_concurrencia AS

   FUNCTION ahora RETURN VARCHAR2 IS
   BEGIN
      RETURN TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS.FF2');
   END;

   PROCEDURE lanzar_sesion_b(p_job VARCHAR2, p_llamada VARCHAR2,
                             p_hab NUMBER, p_aloj NUMBER, p_fecha DATE,
                             p_retardo NUMBER DEFAULT 3) IS
      v_accion VARCHAR2(4000);
   BEGIN
      v_accion := q'[
DECLARE
   v_habs   pkg_turismo.t_lista_habitaciones;
   v_id     NUMBER;
   v_cli    NUMBER;
   v_t0     PLS_INTEGER;   -- centésimas de segundo
BEGIN
   DBMS_SESSION.SLEEP(#RETARDO#);
   v_habs(1) := #HAB#;
   SELECT MAX(id_cliente) INTO v_cli FROM cliente;
   v_t0 := DBMS_UTILITY.GET_TIME;
   DBMS_OUTPUT.PUT_LINE('[B ' || TO_CHAR(SYSTIMESTAMP,'HH24:MI:SS.FF2') ||
      '] SID ' || SYS_CONTEXT('USERENV','SID') || ' intenta reservar la habitación #HAB#');
   BEGIN
      #LLAMADA#;
      UPDATE reserva SET observaciones = 'DEMO_E3 conc sesion B' WHERE id_reserva = v_id;
      COMMIT;
      DBMS_OUTPUT.PUT_LINE('[B ' || TO_CHAR(SYSTIMESTAMP,'HH24:MI:SS.FF2') ||
         '] COMMIT: reserva ' || v_id || ' creada');
   EXCEPTION
      WHEN OTHERS THEN
         ROLLBACK;
         DBMS_OUTPUT.PUT_LINE('[B ' || TO_CHAR(SYSTIMESTAMP,'HH24:MI:SS.FF2') ||
            '] RECHAZADA: ' || SQLERRM);
   END;
   DBMS_OUTPUT.PUT_LINE('[B] tiempo desde el intento hasta la respuesta: ' ||
      TO_CHAR((DBMS_UTILITY.GET_TIME - v_t0) / 100, 'FM990.00') || ' s');
END;]';
      v_accion := REPLACE(v_accion, '#LLAMADA#', p_llamada);
      v_accion := REPLACE(v_accion, '#RETARDO#', TO_CHAR(p_retardo));
      v_accion := REPLACE(v_accion, '#HAB#',     TO_CHAR(p_hab));
      v_accion := REPLACE(v_accion, '#ALOJ#',    TO_CHAR(p_aloj));
      v_accion := REPLACE(v_accion, '#FIN#',     'DATE ''' || TO_CHAR(p_fecha + 2, 'YYYY-MM-DD') || '''');
      v_accion := REPLACE(v_accion, '#INI#',     'DATE ''' || TO_CHAR(p_fecha, 'YYYY-MM-DD') || '''');

      -- OJO: CREATE_JOB hace COMMIT implícito. Por eso se lanza la sesión B
      -- ANTES de que A abra su transacción, nunca en medio.
      DBMS_SCHEDULER.CREATE_JOB(
         job_name   => p_job,
         job_type   => 'PLSQL_BLOCK',
         job_action => v_accion,
         enabled    => TRUE,
         auto_drop  => TRUE);
   END lanzar_sesion_b;

   PROCEDURE mostrar_sesion_b(p_job VARCHAR2, p_desde TIMESTAMP WITH TIME ZONE) IS
      v_salida VARCHAR2(4000);
      v_estado VARCHAR2(30);
   BEGIN
      FOR i IN 1 .. 60 LOOP
         BEGIN
            SELECT output, status INTO v_salida, v_estado
              FROM (SELECT output, status FROM user_scheduler_job_run_details
                     WHERE job_name = p_job AND log_date >= p_desde
                     ORDER BY log_id DESC)
             WHERE ROWNUM = 1;
            EXIT;
         EXCEPTION
            WHEN NO_DATA_FOUND THEN DBMS_SESSION.SLEEP(1);
         END;
      END LOOP;
      DBMS_OUTPUT.PUT_LINE('--- salida de la sesión B (job ' || p_job || ', ' ||
                           NVL(v_estado, 'SIN TERMINAR') || ') ---');
      DBMS_OUTPUT.PUT_LINE(NVL(v_salida, '(el job no terminó en 60 s)'));
   END mostrar_sesion_b;

   PROCEDURE mostrar_bloqueos IS
      v_hay BOOLEAN := FALSE;
   BEGIN
      -- Quién espera a esta sesión, y sobre la fila de qué tabla espera.
      FOR s IN (SELECT s.sid, s.blocking_session, s.event, s.seconds_in_wait,
                       o.object_name
                  FROM v$session s
                  LEFT JOIN user_objects o ON o.object_id = s.row_wait_obj#
                 WHERE s.blocking_session = SYS_CONTEXT('USERENV', 'SID')) LOOP
         v_hay := TRUE;
         DBMS_OUTPUT.PUT_LINE('[A ' || ahora || '] V$SESSION: la sesión ' || s.sid ||
            ' está BLOQUEADA por la sesión ' || s.blocking_session ||
            ' (esta) · evento "' || s.event || '" · espera una fila de ' ||
            NVL(s.object_name, '?') || ' desde hace ' || s.seconds_in_wait || ' s');
      END LOOP;
      -- El bloqueo de transacción (TX) de esta sesión: BLOCK = 1 significa
      -- que hay al menos otra sesión haciendo cola detrás de él.
      FOR l IN (SELECT lmode, block FROM v$lock
                 WHERE sid = SYS_CONTEXT('USERENV', 'SID') AND type = 'TX') LOOP
         DBMS_OUTPUT.PUT_LINE('[A ' || ahora || '] V$LOCK: esta sesión tiene su bloqueo TX en modo ' ||
            l.lmode || ' (exclusivo) · BLOCK = ' || l.block ||
            CASE l.block WHEN 1 THEN ' -> está bloqueando a otra sesión'
                         ELSE ' -> nadie está esperando' END);
      END LOOP;
      IF NOT v_hay THEN
         DBMS_OUTPUT.PUT_LINE('[A ' || ahora || '] V$SESSION: ninguna sesión está esperando a esta.');
      END IF;
   END mostrar_bloqueos;

   FUNCTION reservas_activas(p_hab NUMBER, p_fecha DATE, p_noches NUMBER) RETURN NUMBER IS
      v_n NUMBER;
   BEGIN
      SELECT COUNT(*) INTO v_n
        FROM reserva_habitacion rh
        JOIN reserva r ON r.id_reserva = rh.id_reserva
       WHERE rh.id_habitacion = p_hab
         AND r.estado        <> 'CANCELADA'
         AND r.fecha_checkin  < p_fecha + p_noches
         AND p_fecha          < r.fecha_checkout;
      RETURN v_n;
   END reservas_activas;

END exp_concurrencia;
/


PROMPT
PROMPT ############ 1. ANTES: sin bloqueo explícito (pkg_turismo.sp_crear_reserva) ############
PROMPT ## A reserva y NO confirma. B, en otra sesión, valida disponibilidad: por la
PROMPT ## lectura consistente de Oracle NO ve la fila sin confirmar de A, así que la
PROMPT ## habitación le parece libre. El disparador anti-solape de B tampoco la ve.

DECLARE
   v_habs   pkg_turismo.t_lista_habitaciones;
   v_aloj   NUMBER;
   v_fecha  DATE;
   v_cli    NUMBER;
   v_id     NUMBER;
   v_desde  TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
   v_n      NUMBER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_cli FROM cliente;
   DBMS_OUTPUT.PUT_LINE('Habitación en disputa: ' || v_habs(1) || ' · ' ||
      TO_CHAR(v_fecha, 'YYYY-MM-DD') || ' a ' || TO_CHAR(v_fecha + 2, 'YYYY-MM-DD') ||
      ' · reservas activas antes: ' || exp_concurrencia.reservas_activas(v_habs(1), v_fecha, 2));

   exp_concurrencia.lanzar_sesion_b('EXP_CONC_SIN_BLOQUEO',
      'pkg_turismo.sp_crear_reserva(v_cli, #ALOJ#, #INI#, #FIN#, 1, v_habs, v_id)',
      v_habs(1), v_aloj, v_fecha);

   pkg_turismo.sp_crear_reserva(v_cli, v_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id);
   UPDATE reserva SET observaciones = 'DEMO_E3 conc sesion A' WHERE id_reserva = v_id;
   DBMS_OUTPUT.PUT_LINE('[A ' || exp_concurrencia.ahora || '] reserva ' || v_id ||
                        ' insertada, SIN COMMIT. A espera 8 s...');

   DBMS_SESSION.SLEEP(6);
   exp_concurrencia.mostrar_bloqueos;   -- no hay nada que mostrar: nadie espera
   DBMS_SESSION.SLEEP(2);

   COMMIT;
   DBMS_OUTPUT.PUT_LINE('[A ' || exp_concurrencia.ahora || '] COMMIT');

   exp_concurrencia.mostrar_sesion_b('EXP_CONC_SIN_BLOQUEO', v_desde);

   v_n := exp_concurrencia.reservas_activas(v_habs(1), v_fecha, 2);
   DBMS_OUTPUT.PUT_LINE('Reservas activas de la habitación ' || v_habs(1) ||
                        ' en ese rango: ' || v_n);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n = 2
      THEN 'ANOMALÍA DEMOSTRADA: la misma habitación quedó vendida dos veces'
      ELSE 'No se reprodujo la anomalía (revise que el job haya corrido a tiempo)' END);
END;
/

PROMPT ## Las dos reservas en conflicto (la prueba de la condición de carrera):
SELECT r.id_reserva, rh.id_habitacion, r.fecha_checkin, r.fecha_checkout,
       r.estado, r.observaciones
  FROM reserva r
  JOIN reserva_habitacion rh ON rh.id_reserva = r.id_reserva
 WHERE r.observaciones LIKE 'DEMO_E3 conc%'
 ORDER BY r.id_reserva;

-- Se deshace la doble reserva para que el escenario 2 parta de lo mismo.
DELETE FROM reserva WHERE observaciones LIKE 'DEMO_E3 conc%';
COMMIT;


PROMPT
PROMPT ############ 2. DESPUÉS: con SELECT ... FOR UPDATE (sp_crear_reserva_segura) ############
PROMPT ## A bloquea la fila de HABITACION y reserva sin confirmar. B pide el mismo
PROMPT ## bloqueo y queda en espera (enq: TX - row lock contention). Al COMMIT de A,
PROMPT ## B continúa, vuelve a validar con datos ya confirmados y es rechazada.

DECLARE
   v_habs   pkg_turismo.t_lista_habitaciones;
   v_aloj   NUMBER;
   v_fecha  DATE;
   v_cli    NUMBER;
   v_id     NUMBER;
   v_desde  TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
   v_n      NUMBER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_cli FROM cliente;
   DBMS_OUTPUT.PUT_LINE('Habitación en disputa: ' || v_habs(1) || ' · ' ||
      TO_CHAR(v_fecha, 'YYYY-MM-DD') || ' a ' || TO_CHAR(v_fecha + 2, 'YYYY-MM-DD'));

   exp_concurrencia.lanzar_sesion_b('EXP_CONC_FOR_UPDATE',
      'pkg_transacciones.sp_crear_reserva_segura(v_cli, #ALOJ#, #INI#, #FIN#, 1, v_habs, v_id)',
      v_habs(1), v_aloj, v_fecha);

   pkg_transacciones.sp_crear_reserva_segura(v_cli, v_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id);
   UPDATE reserva SET observaciones = 'DEMO_E3 conc sesion A' WHERE id_reserva = v_id;
   DBMS_OUTPUT.PUT_LINE('[A ' || exp_concurrencia.ahora || '] FOR UPDATE sobre la habitación ' ||
                        v_habs(1) || ' + reserva ' || v_id || ', SIN COMMIT. A espera 8 s...');

   DBMS_SESSION.SLEEP(6);
   exp_concurrencia.mostrar_bloqueos;   -- aquí debe aparecer la sesión B esperando
   DBMS_SESSION.SLEEP(2);

   COMMIT;
   DBMS_OUTPUT.PUT_LINE('[A ' || exp_concurrencia.ahora || '] COMMIT (libera el bloqueo)');

   exp_concurrencia.mostrar_sesion_b('EXP_CONC_FOR_UPDATE', v_desde);

   v_n := exp_concurrencia.reservas_activas(v_habs(1), v_fecha, 2);
   DBMS_OUTPUT.PUT_LINE('Reservas activas de la habitación ' || v_habs(1) ||
                        ' en ese rango: ' || v_n);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n = 1
      THEN 'OK: la competencia se serializó; solo una sesión obtuvo la habitación'
      ELSE 'FALLA: hay ' || v_n || ' reservas' END);
END;
/

DELETE FROM reserva WHERE observaciones LIKE 'DEMO_E3 conc%';
COMMIT;


PROMPT
PROMPT ############ 3. Variantes: FOR UPDATE NOWAIT y FOR UPDATE WAIT 3 ############
PROMPT ## Mismo choque, pero B no está dispuesta a esperar indefinidamente:
PROMPT ##   B1 NOWAIT -> ORA-00054 inmediato, traducido a -20006
PROMPT ##   B2 WAIT 3 -> espera 3 s, ORA-30006, traducido a -20006

DECLARE
   v_habs   pkg_turismo.t_lista_habitaciones;
   v_aloj   NUMBER;
   v_fecha  DATE;
   v_cli    NUMBER;
   v_id     NUMBER;
   v_desde  TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_cli FROM cliente;
   DBMS_OUTPUT.PUT_LINE('Habitación en disputa: ' || v_habs(1));

   exp_concurrencia.lanzar_sesion_b('EXP_CONC_NOWAIT',
      'pkg_transacciones.sp_crear_reserva_segura(v_cli, #ALOJ#, #INI#, #FIN#, 1, v_habs, v_id, p_espera_seg => 0)',
      v_habs(1), v_aloj, v_fecha);
   exp_concurrencia.lanzar_sesion_b('EXP_CONC_WAIT3',
      'pkg_transacciones.sp_crear_reserva_segura(v_cli, #ALOJ#, #INI#, #FIN#, 1, v_habs, v_id, p_espera_seg => 3)',
      v_habs(1), v_aloj, v_fecha);

   pkg_transacciones.sp_crear_reserva_segura(v_cli, v_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id);
   DBMS_OUTPUT.PUT_LINE('[A ' || exp_concurrencia.ahora || '] FOR UPDATE + reserva ' || v_id ||
                        ', SIN COMMIT. A retiene el bloqueo 10 s...');
   DBMS_SESSION.SLEEP(10);

   -- A se arrepiente: ROLLBACK. La habitación vuelve a quedar libre.
   ROLLBACK;
   DBMS_OUTPUT.PUT_LINE('[A ' || exp_concurrencia.ahora || '] ROLLBACK');

   exp_concurrencia.mostrar_sesion_b('EXP_CONC_NOWAIT', v_desde);
   exp_concurrencia.mostrar_sesion_b('EXP_CONC_WAIT3',  v_desde);
END;
/


PROMPT
PROMPT ############ 4. Limpieza ############

DELETE FROM reserva WHERE observaciones LIKE 'DEMO_E3 conc%';
COMMIT;
DROP PACKAGE exp_concurrencia;

PROMPT
PROMPT ############ FIN DEL EXPERIMENTO DE CONCURRENCIA ############
