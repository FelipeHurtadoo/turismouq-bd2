-- =====================================================================
-- TurismoUQ · 12_pruebas_entrega2.sql
-- Ejecutar como: TURISMO_UQ
--
-- Demostración/checklist de la Entrega 2, en el mismo espíritu de
-- 09_validacion.sql: cada bloque imprime "OK" o "FALLA". Pensado para
-- correrlo en vivo durante la sustentación.
--
-- No asume IDs fijos (los conteos derivados varían levemente entre
-- corridas de 06_carga_masiva.sql): todos los datos de prueba se buscan
-- dinámicamente contra lo que haya cargado en ese momento.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO ON

PROMPT
PROMPT ############ 1. fn_valor_estadia vs. valor cargado (estadía multi-temporada) ############

DECLARE
   v_id_rh     NUMBER;
   v_id_hab    NUMBER;
   v_checkin   DATE;
   v_checkout  DATE;
   v_guardado  NUMBER;
   v_calculado NUMBER;
BEGIN
   SELECT id_reserva_habitacion, id_habitacion, fecha_checkin, fecha_checkout, valor_noches
     INTO v_id_rh, v_id_hab, v_checkin, v_checkout, v_guardado
     FROM (
        SELECT rh.id_reserva_habitacion, rh.id_habitacion,
               r.fecha_checkin, r.fecha_checkout, rh.valor_noches
          FROM reserva_habitacion rh
          JOIN reserva    r ON r.id_reserva    = rh.id_reserva
          JOIN dim_tiempo d ON d.fecha >= r.fecha_checkin AND d.fecha < r.fecha_checkout
         GROUP BY rh.id_reserva_habitacion, rh.id_habitacion,
                  r.fecha_checkin, r.fecha_checkout, rh.valor_noches
        HAVING COUNT(DISTINCT d.id_temporada) > 1
     )
    WHERE ROWNUM = 1;

   v_calculado := pkg_turismo.fn_valor_estadia(v_id_hab, v_checkin, v_checkout);

   DBMS_OUTPUT.PUT_LINE('Habitación ' || v_id_hab || ' · ' ||
      TO_CHAR(v_checkin, 'YYYY-MM-DD') || ' a ' || TO_CHAR(v_checkout, 'YYYY-MM-DD'));
   DBMS_OUTPUT.PUT_LINE('  valor guardado en la carga (06_carga_masiva)  : ' || v_guardado);
   DBMS_OUTPUT.PUT_LINE('  valor calculado por fn_valor_estadia          : ' || v_calculado);
   DBMS_OUTPUT.PUT_LINE(CASE WHEN ABS(v_guardado - v_calculado) < 0.01
                             THEN '  OK: coinciden'
                             ELSE '  FALLA: no coinciden' END);
END;
/


PROMPT
PROMPT ############ 2. sp_crear_reserva: excepciones propias y caso de éxito ############

PROMPT === 2.1 Excepción -20001 (checkout <= checkin) ===
DECLARE
   v_id_res  NUMBER;
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_hab  NUMBER;
   v_id_aloj NUMBER;
   v_id_cli  NUMBER;
BEGIN
   -- Sin subconsultas escalares inline dentro de la asignación ni de la
   -- llamada: en esta instancia el parser las rechaza (PLS-00103). Se
   -- resuelven antes, con SELECT ... INTO normales.
   SELECT MIN(id_habitacion) INTO v_id_hab FROM habitacion;
   SELECT id_alojamiento INTO v_id_aloj FROM habitacion WHERE id_habitacion = v_id_hab;
   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   v_habs(1) := v_id_hab;

   pkg_turismo.sp_crear_reserva(
      p_id_cliente     => v_id_cli,
      p_id_alojamiento => v_id_aloj,
      p_fecha_checkin  => DATE '2026-06-10',
      p_fecha_checkout => DATE '2026-06-08',
      p_num_huespedes  => 1,
      p_habitaciones   => v_habs,
      p_id_reserva     => v_id_res);

   DBMS_OUTPUT.PUT_LINE('FALLA: debía lanzar -20001 y no lo hizo');
EXCEPTION
   WHEN OTHERS THEN
      IF SQLCODE = -20001 THEN
         DBMS_OUTPUT.PUT_LINE('OK: -20001 capturado -> ' || SQLERRM);
      ELSE
         RAISE;
      END IF;
END;
/

PROMPT === 2.2 Excepción -20002 (habitación no disponible: se solapa con una reserva activa) ===
DECLARE
   v_id_res  NUMBER;
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_ci      DATE;
   v_co      DATE;
   v_id_cli  NUMBER;
BEGIN
   SELECT rh.id_habitacion, h.id_alojamiento, r.fecha_checkin, r.fecha_checkout
     INTO v_habs(1), v_id_aloj, v_ci, v_co
     FROM reserva_habitacion rh
     JOIN reserva    r ON r.id_reserva    = rh.id_reserva
     JOIN habitacion h ON h.id_habitacion = rh.id_habitacion
    WHERE r.estado <> 'CANCELADA'
      AND ROWNUM = 1;

   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   pkg_turismo.sp_crear_reserva(
      p_id_cliente     => v_id_cli,
      p_id_alojamiento => v_id_aloj,
      p_fecha_checkin  => v_ci,
      p_fecha_checkout => v_co,
      p_num_huespedes  => 1,
      p_habitaciones   => v_habs,
      p_id_reserva     => v_id_res);

   DBMS_OUTPUT.PUT_LINE('FALLA: debía lanzar -20002 y no lo hizo');
EXCEPTION
   WHEN OTHERS THEN
      IF SQLCODE = -20002 THEN
         DBMS_OUTPUT.PUT_LINE('OK: -20002 capturado -> ' || SQLERRM);
      ELSE
         RAISE;
      END IF;
END;
/

PROMPT === 2.3 Excepción -20003 (capacidad excedida) ===
DECLARE
   v_id_res  NUMBER;
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_cap     NUMBER;
   v_libre   DATE;
   v_id_cli  NUMBER;
BEGIN
   -- La habitación cuya última reserva activa termina más temprano (pero no
   -- antes de hoy, para no violar CK_RESERVA_ANTICIP al crear la reserva de
   -- prueba con fecha_reserva = SYSDATE) queda libre desde ese día en
   -- adelante: es un hueco real y verificable sin tener que adivinar fechas.
   SELECT id_habitacion, id_alojamiento, capacidad, libre
     INTO v_habs(1), v_id_aloj, v_cap, v_libre
     FROM (
        SELECT h.id_habitacion, h.id_alojamiento, h.capacidad,
               MAX(r.fecha_checkout) AS libre
          FROM habitacion h
          JOIN reserva_habitacion rh ON rh.id_habitacion = h.id_habitacion
          JOIN reserva r ON r.id_reserva = rh.id_reserva
         WHERE r.estado <> 'CANCELADA'
         GROUP BY h.id_habitacion, h.id_alojamiento, h.capacidad
        HAVING MAX(r.fecha_checkout) BETWEEN TRUNC(SYSDATE) AND DATE '2026-12-29'
         ORDER BY MAX(r.fecha_checkout) ASC
     )
    WHERE ROWNUM = 1;

   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   pkg_turismo.sp_crear_reserva(
      p_id_cliente     => v_id_cli,
      p_id_alojamiento => v_id_aloj,
      p_fecha_checkin  => v_libre,
      p_fecha_checkout => v_libre + 2,
      p_num_huespedes  => v_cap + 5,
      p_habitaciones   => v_habs,
      p_id_reserva     => v_id_res);

   DBMS_OUTPUT.PUT_LINE('FALLA: debía lanzar -20003 y no lo hizo');
EXCEPTION
   WHEN OTHERS THEN
      IF SQLCODE = -20003 THEN
         DBMS_OUTPUT.PUT_LINE('OK: -20003 capturado -> ' || SQLERRM);
      ELSE
         RAISE;
      END IF;
END;
/

PROMPT === 2.4 Caso de éxito (mismo tipo de hueco que en 2.3, huéspedes dentro de la capacidad) ===
DECLARE
   v_id_res  NUMBER;
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_cap     NUMBER;
   v_libre   DATE;
   v_id_cli  NUMBER;
BEGIN
   SELECT id_habitacion, id_alojamiento, capacidad, libre
     INTO v_habs(1), v_id_aloj, v_cap, v_libre
     FROM (
        SELECT h.id_habitacion, h.id_alojamiento, h.capacidad,
               MAX(r.fecha_checkout) AS libre
          FROM habitacion h
          JOIN reserva_habitacion rh ON rh.id_habitacion = h.id_habitacion
          JOIN reserva r ON r.id_reserva = rh.id_reserva
         WHERE r.estado <> 'CANCELADA'
         GROUP BY h.id_habitacion, h.id_alojamiento, h.capacidad
        HAVING MAX(r.fecha_checkout) BETWEEN TRUNC(SYSDATE) AND DATE '2026-12-29'
         ORDER BY MAX(r.fecha_checkout) ASC
     )
    WHERE ROWNUM = 1;

   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   pkg_turismo.sp_crear_reserva(
      p_id_cliente     => v_id_cli,
      p_id_alojamiento => v_id_aloj,
      p_fecha_checkin  => v_libre,
      p_fecha_checkout => v_libre + 2,
      p_num_huespedes  => v_cap,
      p_habitaciones   => v_habs,
      p_id_reserva     => v_id_res);

   COMMIT;  -- sp_crear_reserva no hace commit a propósito (ver 10_pkg_turismo.sql)
   DBMS_OUTPUT.PUT_LINE('OK: reserva creada con id_reserva = ' || v_id_res);
END;
/

PROMPT === Verificación: últimas reservas creadas ===
SELECT r.id_reserva, r.estado, r.fecha_checkin, r.fecha_checkout,
       r.valor_alojamiento, rh.id_habitacion, rh.valor_noches
  FROM reserva r
  JOIN reserva_habitacion rh ON rh.id_reserva = r.id_reserva
 ORDER BY r.id_reserva DESC
 FETCH FIRST 3 ROWS ONLY;


PROMPT
PROMPT ############ 3. sp_liquidar_mes: cursor explícito con parámetros ############

DECLARE
   v_id_aloj NUMBER;
BEGIN
   -- El alojamiento con más estadías cerradas en un mes reciente, para que
   -- el reporte tenga varias líneas y no salga vacío.
   SELECT id_alojamiento
     INTO v_id_aloj
     FROM (
        SELECT id_alojamiento, COUNT(*) AS n
          FROM reserva
         WHERE estado IN ('CONFIRMADA', 'COMPLETADA')
           AND EXTRACT(YEAR  FROM fecha_checkout) = 2025
           AND EXTRACT(MONTH FROM fecha_checkout) = 12
         GROUP BY id_alojamiento
         ORDER BY n DESC
     )
    WHERE ROWNUM = 1;

   pkg_turismo.sp_liquidar_mes(v_id_aloj, 2025, 12);
END;
/


PROMPT
PROMPT ############ 4. trg_tarifa_auditoria: disparador de sentencia ############

DECLARE
   v_id_tarifa NUMBER;
   v_valor_ant NUMBER;
BEGIN
   SELECT id_tarifa, valor_noche INTO v_id_tarifa, v_valor_ant
     FROM tarifa WHERE ROWNUM = 1;

   UPDATE tarifa SET valor_noche = valor_noche + 1000 WHERE id_tarifa = v_id_tarifa;
   COMMIT;

   DBMS_OUTPUT.PUT_LINE('Tarifa ' || v_id_tarifa || ' actualizada: ' ||
                        v_valor_ant || ' -> ' || (v_valor_ant + 1000));
END;
/

PROMPT === Última fila de AUDITORIA_TARIFA (debe reflejar el UPDATE anterior) ===
SELECT * FROM (
   SELECT id_auditoria, fecha_hora, usuario_bd, operacion, id_tarifa,
          valor_anterior, valor_nuevo, filas_afectadas
     FROM auditoria_tarifa
    ORDER BY id_auditoria DESC
) WHERE ROWNUM = 1;


PROMPT
PROMPT ############ 5. trg_rh_anti_solape: disparador de fila (INSERT directo, sin pasar por el paquete) ############
PROMPT ## Se salta a propósito sp_crear_reserva para demostrar que la regla la impone
PROMPT ## la tabla, no el procedimiento.

DECLARE
   v_id_hab  NUMBER;
   v_ci      DATE;
   v_co      DATE;
   v_id_aloj NUMBER;
   v_id_cli  NUMBER;
   v_id_res  NUMBER;
BEGIN
   SELECT rh.id_habitacion, r.fecha_checkin, r.fecha_checkout, r.id_alojamiento
     INTO v_id_hab, v_ci, v_co, v_id_aloj
     FROM reserva_habitacion rh
     JOIN reserva r ON r.id_reserva = rh.id_reserva
    WHERE r.estado <> 'CANCELADA'
      AND ROWNUM = 1;

   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   -- fecha_reserva = v_ci (no SYSDATE): v_ci puede ser una fecha ya pasada,
   -- porque se tomó de una reserva histórica ya cargada, y CK_RESERVA_ANTICIP
   -- exige fecha_reserva <= fecha_checkin.
   v_id_res := seq_reserva.NEXTVAL;
   INSERT INTO reserva (id_reserva, id_cliente, id_alojamiento, fecha_reserva,
                        fecha_checkin, fecha_checkout, num_huespedes, estado)
   VALUES (v_id_res, v_id_cli, v_id_aloj, v_ci, v_ci, v_co, 1, 'CONFIRMADA');

   -- Misma habitación, mismas fechas que una reserva activa que ya existe:
   -- el disparador debe rechazar esta fila.
   INSERT INTO reserva_habitacion (id_reserva, id_habitacion, huespedes, valor_noches)
   VALUES (v_id_res, v_id_hab, 1, 0);

   ROLLBACK;
   DBMS_OUTPUT.PUT_LINE('FALLA: el disparador debía rechazar el INSERT y no lo hizo');
EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK;
      IF SQLCODE = -20002 THEN
         DBMS_OUTPUT.PUT_LINE('OK: -20002 capturado por el disparador -> ' || SQLERRM);
      ELSE
         RAISE;
      END IF;
END;
/

PROMPT
PROMPT ############ FIN DE LAS PRUEBAS DE ENTREGA 2 ############
