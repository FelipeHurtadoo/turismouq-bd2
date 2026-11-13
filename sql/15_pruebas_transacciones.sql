-- =====================================================================
-- TurismoUQ · 15_pruebas_transacciones.sql
-- Ejecutar como: TURISMO_UQ   (después de 14_pkg_transacciones.sql)
--
-- Entrega 3 · Transacciones. Demuestra, con OK / FALLA como en 09 y 12:
--   1. Reserva + pago atómicos: caso feliz (todo o nada -> todo).
--   2. Rollback PARCIAL: el pago falla, ROLLBACK TO sp_antes_pago deshace
--      solo el pago y la reserva queda viva en estado PENDIENTE.
--   3. Rollback TOTAL: la reserva falla, ROLLBACK TO sp_inicio no deja
--      ni cabecera ni líneas ni pago.
--   4. Anatomía del SAVEPOINT paso a paso, con SELECT intermedios.
--   5. Pasarela de pagos: rechazo de la pasarela (-20012, rollback parcial)
--      y pago posterior del saldo con sp_registrar_pago (abono + pago final).
--
-- No asume ids fijos: busca huecos libres con pkg_transacciones.sp_buscar_hueco.
-- Re-ejecutable: al empezar borra las reservas de demostración anteriores
-- (marcadas en OBSERVACIONES con 'DEMO_E3'); no toca el histórico cargado.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO ON

PROMPT
PROMPT ############ 0. Limpieza de corridas anteriores de este guion ############

-- ON DELETE CASCADE de la Entrega 1 se lleva líneas de habitación y pagos.
DELETE FROM reserva WHERE observaciones LIKE 'DEMO_E3%';
COMMIT;


PROMPT
PROMPT ############ 1. Caso feliz: reserva + pago en una sola transacción ############

DECLARE
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_fecha   DATE;
   v_id_cli  NUMBER;
   v_id_res  NUMBER;
   v_res     VARCHAR2(20);
   v_valor   NUMBER;
   v_estado  reserva.estado%TYPE;
   v_pagos   PLS_INTEGER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_id_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   -- Se calcula el total antes, con la misma función que usará el paquete,
   -- para pagar exactamente lo que vale la estadía.
   v_valor := pkg_turismo.fn_valor_estadia(v_habs(1), v_fecha, v_fecha + 2);

   pkg_transacciones.sp_reservar_y_pagar(
      p_id_cliente     => v_id_cli,
      p_id_alojamiento => v_id_aloj,
      p_fecha_checkin  => v_fecha,
      p_fecha_checkout => v_fecha + 2,
      p_num_huespedes  => 1,
      p_habitaciones   => v_habs,
      p_valor_pago     => v_valor,
      p_medio_pago     => 'TARJETA_CREDITO',
      p_id_reserva     => v_id_res,
      p_resultado      => v_res,
      p_observaciones  => 'DEMO_E3 caso feliz');

   SELECT estado INTO v_estado FROM reserva WHERE id_reserva = v_id_res;
   SELECT COUNT(*) INTO v_pagos FROM pago WHERE id_reserva = v_id_res;

   DBMS_OUTPUT.PUT_LINE('Reserva ' || v_id_res || ' · habitación ' || v_habs(1) ||
      ' · ' || TO_CHAR(v_fecha, 'YYYY-MM-DD') || ' (2 noches) · valor ' || v_valor);
   DBMS_OUTPUT.PUT_LINE('  resultado = ' || v_res || ' · estado = ' || v_estado ||
      ' · pagos = ' || v_pagos);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_res = 'PAGADA' AND v_estado = 'CONFIRMADA' AND v_pagos = 1
                             THEN '  OK: reserva y pago confirmados juntos'
                             ELSE '  FALLA' END);
END;
/


PROMPT
PROMPT ############ 2. Rollback PARCIAL: el pago falla, la reserva sobrevive ############

PROMPT === 2.1 Pago mayor al total de la reserva (excepción propia -20011) ===
DECLARE
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_fecha   DATE;
   v_id_cli  NUMBER;
   v_id_res  NUMBER;
   v_res     VARCHAR2(20);
   v_estado  reserva.estado%TYPE;
   v_obs     reserva.observaciones%TYPE;
   v_lineas  PLS_INTEGER;
   v_pagos   PLS_INTEGER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(3, v_habs(1), v_id_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   pkg_transacciones.sp_reservar_y_pagar(
      p_id_cliente     => v_id_cli,
      p_id_alojamiento => v_id_aloj,
      p_fecha_checkin  => v_fecha,
      p_fecha_checkout => v_fecha + 3,
      p_num_huespedes  => 1,
      p_habitaciones   => v_habs,
      p_valor_pago     => 999999999,           -- muy por encima del total
      p_medio_pago     => 'PSE',
      p_id_reserva     => v_id_res,
      p_resultado      => v_res,
      p_observaciones  => 'DEMO_E3 rollback parcial (monto)');

   SELECT estado, observaciones INTO v_estado, v_obs FROM reserva WHERE id_reserva = v_id_res;
   SELECT COUNT(*) INTO v_lineas FROM reserva_habitacion WHERE id_reserva = v_id_res;
   SELECT COUNT(*) INTO v_pagos  FROM pago               WHERE id_reserva = v_id_res;

   DBMS_OUTPUT.PUT_LINE('Reserva ' || v_id_res || ' · resultado = ' || v_res);
   DBMS_OUTPUT.PUT_LINE('  estado = ' || v_estado || ' · líneas de habitación = ' || v_lineas ||
                        ' · pagos = ' || v_pagos);
   DBMS_OUTPUT.PUT_LINE('  observaciones = ' || v_obs);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_res = 'PENDIENTE_PAGO' AND v_estado = 'PENDIENTE'
                              AND v_lineas = 1 AND v_pagos = 0
                             THEN '  OK: se deshizo SOLO el pago; la reserva quedó PENDIENTE'
                             ELSE '  FALLA' END);
END;
/

PROMPT === 2.2 Medio de pago inválido (lo rechaza el CHECK ck_pago_medio, ORA-02290) ===
DECLARE
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_fecha   DATE;
   v_id_cli  NUMBER;
   v_id_res  NUMBER;
   v_res     VARCHAR2(20);
   v_estado  reserva.estado%TYPE;
   v_pagos   PLS_INTEGER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_id_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   pkg_transacciones.sp_reservar_y_pagar(
      p_id_cliente     => v_id_cli,
      p_id_alojamiento => v_id_aloj,
      p_fecha_checkin  => v_fecha,
      p_fecha_checkout => v_fecha + 2,
      p_num_huespedes  => 1,
      p_habitaciones   => v_habs,
      p_valor_pago     => 10000,
      p_medio_pago     => 'BITCOIN',             -- no está en el CHECK
      p_id_reserva     => v_id_res,
      p_resultado      => v_res,
      p_observaciones  => 'DEMO_E3 rollback parcial (medio)');

   SELECT estado INTO v_estado FROM reserva WHERE id_reserva = v_id_res;
   SELECT COUNT(*) INTO v_pagos FROM pago WHERE id_reserva = v_id_res;

   DBMS_OUTPUT.PUT_LINE('Reserva ' || v_id_res || ' · resultado = ' || v_res ||
                        ' · estado = ' || v_estado || ' · pagos = ' || v_pagos);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_estado = 'PENDIENTE' AND v_pagos = 0
                             THEN '  OK: el error del motor también produce el rollback parcial'
                             ELSE '  FALLA' END);
END;
/


PROMPT === 2.3 La pasarela de pagos rechaza la transacción (excepción propia -20012) ===
DECLARE
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_fecha   DATE;
   v_id_cli  NUMBER;
   v_id_res  NUMBER;
   v_res     VARCHAR2(20);
   v_valor   NUMBER;
   v_estado  reserva.estado%TYPE;
   v_pagos   PLS_INTEGER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_id_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;
   v_valor := pkg_turismo.fn_valor_estadia(v_habs(1), v_fecha, v_fecha + 2);

   -- Así llama la interfaz web cuando la pasarela responde "fondos
   -- insuficientes": el monto y el medio son válidos, pero la respuesta no.
   pkg_transacciones.sp_reservar_y_pagar(
      p_id_cliente         => v_id_cli,
      p_id_alojamiento     => v_id_aloj,
      p_fecha_checkin      => v_fecha,
      p_fecha_checkout     => v_fecha + 2,
      p_num_huespedes      => 1,
      p_habitaciones       => v_habs,
      p_valor_pago         => v_valor,
      p_medio_pago         => 'TARJETA_CREDITO',
      p_id_reserva         => v_id_res,
      p_resultado          => v_res,
      p_observaciones      => 'DEMO_E3 pasarela rechazada',
      p_respuesta_pasarela => 'RECHAZADO',
      p_referencia         => 'TUQ-DEMO-RECHAZO',
      p_detalle_pasarela   => 'fondos insuficientes');

   SELECT estado INTO v_estado FROM reserva WHERE id_reserva = v_id_res;
   SELECT COUNT(*) INTO v_pagos FROM pago WHERE id_reserva = v_id_res;

   DBMS_OUTPUT.PUT_LINE('Reserva ' || v_id_res || ' · resultado = ' || v_res ||
                        ' · estado = ' || v_estado || ' · pagos = ' || v_pagos);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_estado = 'PENDIENTE' AND v_pagos = 0
                             THEN '  OK: el rechazo de la pasarela produjo el rollback parcial'
                             ELSE '  FALLA' END);
END;
/


PROMPT
PROMPT ############ 3. Rollback TOTAL: la reserva falla, no queda nada ############

DECLARE
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_fecha   DATE;
   v_cap     NUMBER;
   v_id_cli  NUMBER;
   v_id_res  NUMBER;
   v_res     VARCHAR2(20);
   v_antes   PLS_INTEGER;
   v_despues PLS_INTEGER;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_id_aloj, v_fecha);
   SELECT capacidad INTO v_cap FROM habitacion WHERE id_habitacion = v_habs(1);
   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;
   SELECT COUNT(*) INTO v_antes FROM reserva;

   BEGIN
      pkg_transacciones.sp_reservar_y_pagar(
         p_id_cliente     => v_id_cli,
         p_id_alojamiento => v_id_aloj,
         p_fecha_checkin  => v_fecha,
         p_fecha_checkout => v_fecha + 2,
         p_num_huespedes  => v_cap + 5,          -- capacidad excedida: -20003
         p_habitaciones   => v_habs,
         p_valor_pago     => 10000,
         p_medio_pago     => 'EFECTIVO',
         p_id_reserva     => v_id_res,
         p_resultado      => v_res,
         p_observaciones  => 'DEMO_E3 rollback total');
      DBMS_OUTPUT.PUT_LINE('FALLA: debía lanzar -20003 y no lo hizo');
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -20003 THEN
            DBMS_OUTPUT.PUT_LINE('Excepción propagada al llamador -> ' || SQLERRM);
         ELSE
            RAISE;
         END IF;
   END;

   SELECT COUNT(*) INTO v_despues FROM reserva;
   DBMS_OUTPUT.PUT_LINE('  reservas antes = ' || v_antes || ' · después = ' || v_despues);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_antes = v_despues
                             THEN '  OK: ROLLBACK TO sp_inicio no dejó nada grabado'
                             ELSE '  FALLA' END);
END;
/


PROMPT
PROMPT ############ 4. Anatomía del SAVEPOINT, paso a paso ############
PROMPT ## Lo mismo que hace sp_reservar_y_pagar por dentro, pero visible:
PROMPT ## después de cada paso se cuenta qué ve la propia transacción.

DECLARE
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_fecha   DATE;
   v_id_cli  NUMBER;
   v_id_res  NUMBER;
   v_res     PLS_INTEGER;
   v_lin     PLS_INTEGER;
   v_pag     PLS_INTEGER;

   PROCEDURE foto(p_paso VARCHAR2) IS
   BEGIN
      SELECT COUNT(*) INTO v_res FROM reserva            WHERE id_reserva = v_id_res;
      SELECT COUNT(*) INTO v_lin FROM reserva_habitacion WHERE id_reserva = v_id_res;
      SELECT COUNT(*) INTO v_pag FROM pago               WHERE id_reserva = v_id_res;
      DBMS_OUTPUT.PUT_LINE(RPAD(p_paso, 44) || '| reserva ' || v_res ||
                           ' | líneas ' || v_lin || ' | pagos ' || v_pag);
   END;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_id_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   SAVEPOINT demo_inicio;
   pkg_turismo.sp_crear_reserva(v_id_cli, v_id_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id_res);
   foto('1) reserva creada');

   SAVEPOINT demo_antes_pago;
   INSERT INTO pago (id_reserva, fecha_pago, valor, medio_pago, estado, referencia)
   VALUES (v_id_res, SYSDATE, 50000, 'EFECTIVO', 'APROBADO', 'DEMO-E3-' || v_id_res || '-A');
   foto('2) primer pago insertado');

   INSERT INTO pago (id_reserva, fecha_pago, valor, medio_pago, estado, referencia)
   VALUES (v_id_res, SYSDATE, 20000, 'EFECTIVO', 'APROBADO', 'DEMO-E3-' || v_id_res || '-B');
   foto('3) segundo pago insertado');

   ROLLBACK TO SAVEPOINT demo_antes_pago;
   foto('4) ROLLBACK TO demo_antes_pago');

   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_res = 1 AND v_lin = 1 AND v_pag = 0
                             THEN 'OK: los pagos se deshicieron y la reserva sigue en la transacción'
                             ELSE 'FALLA' END);

   ROLLBACK TO SAVEPOINT demo_inicio;
   foto('5) ROLLBACK TO demo_inicio');

   -- La transacción sigue ABIERTA después de un ROLLBACK TO: un SAVEPOINT
   -- no termina la transacción, solo la recorta. Se cierra explícitamente.
   ROLLBACK;
END;
/


PROMPT
PROMPT ############ 5. Pagar después: sp_registrar_pago sobre la reserva PENDIENTE ############
PROMPT ## La reserva del bloque 2.3 quedó PENDIENTE. El cliente vuelve y paga:
PROMPT ## primero un abono, luego un intento rechazado, luego el saldo.

DECLARE
   v_id_res  NUMBER;
   v_total   NUMBER;
   v_res     VARCHAR2(20);
   v_msg     VARCHAR2(300);
   v_estado  reserva.estado%TYPE;
   v_pagos   PLS_INTEGER;
BEGIN
   SELECT id_reserva, valor_total INTO v_id_res, v_total
     FROM reserva WHERE observaciones LIKE 'DEMO_E3 pasarela rechazada%';

   pkg_transacciones.sp_registrar_pago(v_id_res, 100000, 'PSE', v_res, v_msg,
                                       p_referencia => 'TUQ-DEMO-ABONO');
   DBMS_OUTPUT.PUT_LINE('5.1 Abono de 100000      -> ' || v_res || ' · ' || v_msg);

   pkg_transacciones.sp_registrar_pago(v_id_res, v_total - 100000, 'TARJETA_DEBITO', v_res, v_msg,
                                       p_respuesta_pasarela => 'RECHAZADO',
                                       p_referencia => 'TUQ-DEMO-RECH2',
                                       p_detalle_pasarela => 'tarjeta bloqueada');
   DBMS_OUTPUT.PUT_LINE('5.2 Saldo, rechazado     -> ' || v_res || ' · ' || v_msg);

   pkg_transacciones.sp_registrar_pago(v_id_res, v_total - 100000, 'TARJETA_CREDITO', v_res, v_msg,
                                       p_referencia => 'TUQ-DEMO-SALDO');
   DBMS_OUTPUT.PUT_LINE('5.3 Saldo, aprobado      -> ' || v_res || ' · ' || v_msg);

   SELECT estado INTO v_estado FROM reserva WHERE id_reserva = v_id_res;
   SELECT COUNT(*) INTO v_pagos FROM pago WHERE id_reserva = v_id_res;
   DBMS_OUTPUT.PUT_LINE('Reserva ' || v_id_res || ' · estado = ' || v_estado || ' · pagos = ' || v_pagos);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_estado = 'CONFIRMADA' AND v_pagos = 2
                             THEN 'OK: 2 pagos aprobados, el rechazado no dejó rastro y la reserva quedó CONFIRMADA'
                             ELSE 'FALLA' END);
END;
/


PROMPT
PROMPT === Reservas de demostración que quedaron grabadas (COMMIT) en la base ===
SELECT r.id_reserva, r.estado, r.fecha_checkin, r.fecha_checkout, r.valor_total,
       (SELECT NVL(SUM(p.valor), 0) FROM pago p WHERE p.id_reserva = r.id_reserva) AS pagado,
       r.observaciones
  FROM reserva r
 WHERE r.observaciones LIKE 'DEMO_E3%'
 ORDER BY r.id_reserva;

PROMPT
PROMPT ############ FIN DE LAS PRUEBAS DE TRANSACCIONES ############
