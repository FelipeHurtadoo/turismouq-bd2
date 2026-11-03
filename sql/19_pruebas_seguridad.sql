-- =====================================================================
-- TurismoUQ · 19_pruebas_seguridad.sql
-- Ejecutar con sqlplus o con F5 en SQL Developer (después de 18).
-- El script se CONECTA como cada usuario de demostración y comprueba lo
-- que puede y lo que NO puede hacer. Cada prueba imprime OK / FALLA.
--
-- Cadena de conexión: localhost:1521/XEPDB1. Si su instalación usa otra,
-- cámbiela en la línea DEFINE de abajo.
-- Al final vuelve a conectarse como TURISMO_UQ.
-- =====================================================================

DEFINE cnx = localhost:1521/XEPDB1
SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO OFF
SET VERIFY OFF

-- =====================================================================
PROMPT
PROMPT ############ 1. RECEP1 (rol_recepcion, alojamiento 1) ############
-- =====================================================================
CONNECT recep1/"Demo_UQ2026"@&cnx
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
   v_n    NUMBER;
   v_min  NUMBER;
   v_max  NUMBER;

   PROCEDURE debe_fallar(p_desc VARCHAR2, p_sql VARCHAR2, p_code NUMBER) IS
   BEGIN
      EXECUTE IMMEDIATE p_sql;
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('FALLA: ' || p_desc || ' -> debía ser rechazado');
   EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE(CASE WHEN SQLCODE = p_code THEN 'OK   : ' ELSE 'FALLA: ' END ||
                           p_desc || ' -> ' || SQLERRM);
   END;
BEGIN
   DBMS_OUTPUT.PUT_LINE('Conectado como ' || USER);

   SELECT COUNT(*), MIN(id_alojamiento), MAX(id_alojamiento)
     INTO v_n, v_min, v_max
     FROM turismo_uq.v_recepcion_reservas;
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n > 0 AND v_min = 1 AND v_max = 1 THEN 'OK   : ' ELSE 'FALLA: ' END ||
      'la vista v_recepcion_reservas devuelve ' || v_n || ' reservas, todas del alojamiento ' || v_min);

   SELECT COUNT(*) INTO v_n FROM turismo_uq.v_recepcion_habitaciones;
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n > 0 THEN 'OK   : ' ELSE 'FALLA: ' END ||
      'v_recepcion_habitaciones muestra ' || v_n || ' habitaciones de su alojamiento');

   -- Las TABLAS no existen para recepción: ni siquiera "las ve" (ORA-00942).
   debe_fallar('SELECT directo a la tabla RESERVA',  'SELECT COUNT(*) FROM turismo_uq.reserva',  -942);
   debe_fallar('SELECT directo a la tabla CLIENTE',  'SELECT COUNT(*) FROM turismo_uq.cliente',  -942);
   debe_fallar('SELECT directo a la tabla PAGO',     'SELECT COUNT(*) FROM turismo_uq.pago',     -942);
   -- Sobre la vista solo tiene SELECT: modificarla es privilegio insuficiente.
   debe_fallar('UPDATE sobre la vista de reservas',
               'UPDATE turismo_uq.v_recepcion_reservas SET num_huespedes = 1 WHERE ROWNUM = 1', -1031);
   debe_fallar('Vistas del administrador (tarifas)', 'SELECT COUNT(*) FROM turismo_uq.v_admin_tarifas', -942);
   debe_fallar('Crear una tabla propia', 'CREATE TABLE prueba_recep (x NUMBER)', -1031);
END;
/

PROMPT === Recepción reserva y cobra por el PROCEDIMIENTO (no por INSERT) ===
DECLARE
   v_habs    turismo_uq.pkg_transacciones.t_lista_habitaciones;
   v_aloj    NUMBER;
   v_fecha   DATE;
   v_cli     NUMBER;
   v_id      NUMBER;
   v_res     VARCHAR2(20);
BEGIN
   SELECT MIN(id_cliente) INTO v_cli FROM turismo_uq.v_recepcion_reservas;

   -- a) En SU alojamiento: permitido. p_commit => FALSE y ROLLBACK al final
   --    para no dejar datos de prueba.
   turismo_uq.pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha, p_solo_aloj => 1);
   turismo_uq.pkg_transacciones.sp_reservar_y_pagar(
      v_cli, 1, v_fecha, v_fecha + 2, 1, v_habs, 10000, 'EFECTIVO',
      v_id, v_res, p_commit => FALSE);
   DBMS_OUTPUT.PUT_LINE('OK   : reserva ' || v_id || ' en el alojamiento 1 · resultado ' || v_res);
   ROLLBACK;

   -- b) En un alojamiento AJENO: el paquete lo rechaza con -20020.
   turismo_uq.pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha, p_solo_aloj => 2);
   BEGIN
      turismo_uq.pkg_transacciones.sp_reservar_y_pagar(
         v_cli, 2, v_fecha, v_fecha + 2, 1, v_habs, 10000, 'EFECTIVO',
         v_id, v_res, p_commit => FALSE);
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('FALLA: reservó en un alojamiento ajeno');
   EXCEPTION WHEN OTHERS THEN
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE(CASE WHEN SQLCODE = -20020 THEN 'OK   : ' ELSE 'FALLA: ' END ||
                           'reserva en el alojamiento 2 -> ' || SQLERRM);
   END;
END;
/

PROMPT === Límites del perfil que rigen a este usuario ===
SELECT resource_name, limit
  FROM user_resource_limits
 WHERE resource_name IN ('SESSIONS_PER_USER', 'IDLE_TIME', 'CONNECT_TIME', 'LOGICAL_READS_PER_CALL')
 ORDER BY resource_name;

-- =====================================================================
PROMPT
PROMPT ############ 2. RECEP2 (rol_recepcion, alojamiento 2): misma vista, otras filas ############
-- =====================================================================
CONNECT recep2/"Demo_UQ2026"@&cnx
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
   v_n NUMBER; v_min NUMBER; v_max NUMBER;
BEGIN
   SELECT COUNT(*), MIN(id_alojamiento), MAX(id_alojamiento)
     INTO v_n, v_min, v_max
     FROM turismo_uq.v_recepcion_reservas;
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n > 0 AND v_min = 2 AND v_max = 2 THEN 'OK   : ' ELSE 'FALLA: ' END ||
      USER || ' ve ' || v_n || ' reservas, todas del alojamiento ' || v_min ||
      ' (mismo GRANT que RECEP1, filas distintas)');
END;
/

-- =====================================================================
PROMPT
PROMPT ############ 3. ADMIN1 (rol_admin_alojamiento, alojamiento 1) ############
-- =====================================================================
CONNECT admin1/"Demo_UQ2026"@&cnx
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
   v_n     NUMBER;
   v_id    NUMBER;

   PROCEDURE debe_fallar(p_desc VARCHAR2, p_sql VARCHAR2, p_code NUMBER) IS
   BEGIN
      EXECUTE IMMEDIATE p_sql;
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('FALLA: ' || p_desc || ' -> debía ser rechazado');
   EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE(CASE WHEN SQLCODE = p_code THEN 'OK   : ' ELSE 'FALLA: ' END ||
                           p_desc || ' -> ' || SQLERRM);
   END;
BEGIN
   -- Hereda recepción por la jerarquía de roles
   SELECT COUNT(*) INTO v_n FROM turismo_uq.v_recepcion_reservas;
   DBMS_OUTPUT.PUT_LINE('OK   : hereda rol_recepcion · ve ' || v_n || ' reservas de su alojamiento');

   -- Cambia un precio de SU alojamiento por la vista. El disparador de la
   -- Entrega 2 lo audita con ADMIN1 como autor (lo comprueba el auditor).
   SELECT MIN(id_tarifa) INTO v_id FROM turismo_uq.v_admin_tarifas;
   UPDATE turismo_uq.v_admin_tarifas SET valor_noche = valor_noche + 1000 WHERE id_tarifa = v_id;
   DBMS_OUTPUT.PUT_LINE(CASE WHEN SQL%ROWCOUNT = 1 THEN 'OK   : ' ELSE 'FALLA: ' END ||
      'UPDATE de la tarifa ' || v_id || ' (+1000) por v_admin_tarifas');
   COMMIT;
   UPDATE turismo_uq.v_admin_tarifas SET valor_noche = valor_noche - 1000 WHERE id_tarifa = v_id;
   COMMIT;
   DBMS_OUTPUT.PUT_LINE('OK   : tarifa ' || v_id || ' restaurada (-1000)');

   -- Tarifas de otro alojamiento: no existen para él (la vista las filtra)
   EXECUTE IMMEDIATE 'UPDATE turismo_uq.v_admin_tarifas SET valor_noche = 1 WHERE id_alojamiento = 2';
   DBMS_OUTPUT.PUT_LINE(CASE WHEN SQL%ROWCOUNT = 0 THEN 'OK   : ' ELSE 'FALLA: ' END ||
      'UPDATE sobre tarifas del alojamiento 2 afectó ' || SQL%ROWCOUNT || ' filas');
   ROLLBACK;

   debe_fallar('Mover una tarifa a otro alojamiento (columna sin privilegio)',
               'UPDATE turismo_uq.v_admin_tarifas SET id_alojamiento = 2 WHERE ROWNUM = 1', -1031);
   debe_fallar('UPDATE directo a la tabla TARIFA',
               'UPDATE turismo_uq.tarifa SET valor_noche = 1 WHERE ROWNUM = 1', -942);
   debe_fallar('Leer la auditoría', 'SELECT COUNT(*) FROM turismo_uq.auditoria_tarifa', -942);
END;
/

-- =====================================================================
PROMPT
PROMPT ############ 4. GERENTE1 (rol_gerente, transversal y de solo lectura) ############
-- =====================================================================
CONNECT gerente1/"Demo_UQ2026"@&cnx
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
   v_n NUMBER; v_m NUMBER;

   PROCEDURE debe_fallar(p_desc VARCHAR2, p_sql VARCHAR2, p_code NUMBER) IS
   BEGIN
      EXECUTE IMMEDIATE p_sql;
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('FALLA: ' || p_desc || ' -> debía ser rechazado');
   EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE(CASE WHEN SQLCODE = p_code THEN 'OK   : ' ELSE 'FALLA: ' END ||
                           p_desc || ' -> ' || SQLERRM);
   END;
BEGIN
   SELECT COUNT(*), COUNT(DISTINCT id_alojamiento) INTO v_n, v_m FROM turismo_uq.reserva;
   DBMS_OUTPUT.PUT_LINE('OK   : lee RESERVA completa · ' || v_n || ' reservas de ' || v_m || ' alojamientos');
   SELECT COUNT(*) INTO v_n FROM turismo_uq.mv_ocupacion_mensual;
   DBMS_OUTPUT.PUT_LINE('OK   : lee la vista materializada · ' || v_n || ' filas');

   debe_fallar('Modificar una tarifa', 'UPDATE turismo_uq.tarifa SET valor_noche = 1 WHERE ROWNUM = 1', -1031);
   debe_fallar('Borrar una reserva',   'DELETE FROM turismo_uq.reserva WHERE ROWNUM = 1',              -1031);
   debe_fallar('Leer la auditoría',    'SELECT COUNT(*) FROM turismo_uq.auditoria_tarifa',            -942);
END;
/

-- =====================================================================
PROMPT
PROMPT ############ 5. AUDITOR1 (rol_auditor, evidencia en solo lectura) ############
-- =====================================================================
CONNECT auditor1/"Demo_UQ2026"@&cnx
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
   v_n NUMBER;

   PROCEDURE debe_fallar(p_desc VARCHAR2, p_sql VARCHAR2, p_code NUMBER) IS
   BEGIN
      EXECUTE IMMEDIATE p_sql;
      ROLLBACK;
      DBMS_OUTPUT.PUT_LINE('FALLA: ' || p_desc || ' -> debía ser rechazado');
   EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE(CASE WHEN SQLCODE = p_code THEN 'OK   : ' ELSE 'FALLA: ' END ||
                           p_desc || ' -> ' || SQLERRM);
   END;
BEGIN
   SELECT COUNT(*) INTO v_n FROM turismo_uq.auditoria_tarifa WHERE usuario_bd = 'ADMIN1';
   DBMS_OUTPUT.PUT_LINE(CASE WHEN v_n >= 2 THEN 'OK   : ' ELSE 'FALLA: ' END ||
      'la auditoría registra ' || v_n || ' cambios hechos por ADMIN1');

   debe_fallar('Borrar evidencia de la auditoría', 'DELETE FROM turismo_uq.auditoria_tarifa', -1031);
   debe_fallar('Leer datos personales (CLIENTE)',  'SELECT COUNT(*) FROM turismo_uq.cliente',  -942);
   debe_fallar('Ejecutar la liquidación',
               'BEGIN turismo_uq.pkg_turismo.sp_liquidar_mes(1, 2025, 12); END;', -6550);
END;
/

PROMPT === Lo que ve el auditor: últimos cambios de tarifa y su autor ===
SELECT * FROM (
   SELECT id_auditoria, fecha_hora, usuario_bd, operacion, id_tarifa,
          valor_anterior, valor_nuevo
     FROM turismo_uq.auditoria_tarifa
    ORDER BY id_auditoria DESC)
 WHERE ROWNUM <= 2;

-- =====================================================================
PROMPT
PROMPT ############ 6. Límite de sesiones del perfil (prueba manual) ############
-- =====================================================================
PROMPT ## SESSIONS_PER_USER = 2 no se puede probar desde UNA sola sesión.
PROMPT ## Abra tres terminales y en cada una:
PROMPT ##    sqlplus recep1/Demo_UQ2026@localhost:1521/XEPDB1
PROMPT ## Las dos primeras conectan; la tercera recibe:
PROMPT ##    ORA-02391: exceeded simultaneous SESSIONS_PER_USER limit

CONNECT turismo_uq/"TurismoUQ_2026"@&cnx
PROMPT
PROMPT ############ FIN DE LAS PRUEBAS DE SEGURIDAD (de nuevo como TURISMO_UQ) ############
