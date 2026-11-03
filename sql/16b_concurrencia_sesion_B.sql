-- =====================================================================
-- TurismoUQ · 16b_concurrencia_sesion_B.sql
-- Ejecutar como: TURISMO_UQ, en la VENTANA B (sesión distinta de la A)
--
-- Pareja de 16a_concurrencia_sesion_A.sql. Ejecute UN PASO a la vez,
-- solo cuando la ventana A lo indique.
--
-- Por qué B encuentra la MISMA habitación que A: sp_buscar_hueco devuelve
-- el primer hueco en orden determinista, y B no ve la reserva SIN
-- CONFIRMAR de A (lectura consistente). Para B, esa habitación está libre.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

-- ---------------------------------------------------------------------
-- PASO B1 · (escenario 1, con A sin confirmar) reservar SIN bloqueo
-- Resultado esperado: la reserva se crea -> doble reserva.
-- ---------------------------------------------------------------------
DECLARE
   v_habs  pkg_turismo.t_lista_habitaciones;
   v_aloj  NUMBER;
   v_fecha DATE;
   v_cli   NUMBER;
   v_id    NUMBER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha);
   SELECT MAX(id_cliente) INTO v_cli FROM cliente;
   pkg_turismo.sp_crear_reserva(v_cli, v_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id);
   UPDATE reserva SET observaciones = 'DEMO_E3 conc manual B' WHERE id_reserva = v_id;
   COMMIT;
   DBMS_OUTPUT.PUT_LINE('[B ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] reserva ' || v_id ||
      ' · habitación ' || v_habs(1) || ' · ' || TO_CHAR(v_fecha, 'YYYY-MM-DD') || ' · COMMIT');
   DBMS_OUTPUT.PUT_LINE('>>> B no vio la reserva de A. Vuelva a la ventana A, PASO A2.');
END;
/

-- ---------------------------------------------------------------------
-- PASO B2 · (escenario 2, con A bloqueando) reservar CON FOR UPDATE
-- Resultado esperado: este bloque se QUEDA ESPERANDO hasta el PASO A5.
-- Luego termina con ORA-20002 (la habitación ya no está disponible).
-- ---------------------------------------------------------------------
DECLARE
   v_habs  pkg_turismo.t_lista_habitaciones;
   v_aloj  NUMBER;
   v_fecha DATE;
   v_cli   NUMBER;
   v_id    NUMBER;
   v_t0    PLS_INTEGER;   -- centésimas de segundo (DBMS_UTILITY.GET_TIME)
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha);
   SELECT MAX(id_cliente) INTO v_cli FROM cliente;
   v_t0 := DBMS_UTILITY.GET_TIME;
   DBMS_OUTPUT.PUT_LINE('[B ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] pide la habitación ' || v_habs(1));
   BEGIN
      pkg_transacciones.sp_crear_reserva_segura(v_cli, v_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id);
      UPDATE reserva SET observaciones = 'DEMO_E3 conc manual B' WHERE id_reserva = v_id;
      COMMIT;
      DBMS_OUTPUT.PUT_LINE('[B] reserva ' || v_id || ' creada (inesperado si A ya la tenía)');
   EXCEPTION
      WHEN OTHERS THEN
         ROLLBACK;
         DBMS_OUTPUT.PUT_LINE('[B ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] RECHAZADA tras esperar ' ||
            TO_CHAR((DBMS_UTILITY.GET_TIME - v_t0) / 100, 'FM9990.0') || ' s: ' || SQLERRM);
   END;
END;
/

-- ---------------------------------------------------------------------
-- PASO B2-bis (alternativa) · igual que B2 pero con NOWAIT: no espera,
-- falla de inmediato con -20006 (ORA-00054). Úselo en lugar de B2 si
-- quiere mostrar la diferencia. Cambie 0 por 5 para FOR UPDATE WAIT 5.
-- ---------------------------------------------------------------------
DECLARE
   v_habs  pkg_turismo.t_lista_habitaciones;
   v_aloj  NUMBER;
   v_fecha DATE;
   v_cli   NUMBER;
   v_id    NUMBER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha);
   SELECT MAX(id_cliente) INTO v_cli FROM cliente;
   pkg_transacciones.sp_crear_reserva_segura(v_cli, v_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id,
                                             p_espera_seg => 0);
   COMMIT;
EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('[B ' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] ' || SQLERRM);
END;
/
