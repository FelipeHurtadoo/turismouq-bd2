-- =====================================================================
-- TurismoUQ · 18_seguridad.sql
-- Ejecutar como: TURISMO_UQ   (después de 13_privilegios_entrega3.sql)
--
-- Entrega 3 · Seguridad:
--   1. Cuatro roles con privilegios diferenciados:
--        ROL_RECEPCION · ROL_ADMIN_ALOJAMIENTO · ROL_GERENTE · ROL_AUDITOR
--   2. Recepción accede SOLO a través de vistas, nunca a las tablas.
--   3. Un perfil con límites de sesión: PERFIL_TURISMO_OPERATIVO.
--   4. Cinco usuarios de base de datos de demostración, uno por cada fila
--      de USUARIO_SISTEMA que representan (mismo nombre de usuario).
--
-- El vínculo entre el usuario de BD y su alojamiento ya estaba modelado
-- desde la Entrega 1: USUARIO_SISTEMA(username, rol, id_alojamiento) con el
-- CHECK ck_usuario_ambito (recepción y admin pertenecen a UN alojamiento;
-- gerente y auditor son transversales). Las vistas filtran por
--     SYS_CONTEXT('USERENV', 'SESSION_USER')  ->  USUARIO_SISTEMA.username
-- así que RECEP1 solo ve el alojamiento 1 y RECEP2 solo el 2, con la misma
-- vista y el mismo GRANT. Ninguna tabla cambió.
--
-- Re-ejecutable: borra y vuelve a crear usuarios, roles y perfil. Si se
-- corre 02_limpieza.sql, las vistas desaparecen (y con ellas sus GRANT):
-- basta con volver a ejecutar este script.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO ON

-- ---------------------------------------------------------------------
-- 0. Limpieza (orden: usuarios -> perfil -> roles)
-- ---------------------------------------------------------------------
DECLARE
   PROCEDURE ejec(p_sql VARCHAR2) IS
   BEGIN
      EXECUTE IMMEDIATE p_sql;
      DBMS_OUTPUT.PUT_LINE('OK   : ' || p_sql);
   EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('SKIP : ' || p_sql || ' -> ' || SQLERRM);
   END;
BEGIN
   FOR u IN (SELECT column_value AS nombre
               FROM TABLE(sys.odcivarchar2list('RECEP1', 'RECEP2', 'ADMIN1', 'GERENTE1', 'AUDITOR1'))) LOOP
      ejec('DROP USER ' || u.nombre || ' CASCADE');
   END LOOP;
   ejec('DROP PROFILE perfil_turismo_operativo CASCADE');
   ejec('DROP ROLE rol_recepcion');
   ejec('DROP ROLE rol_admin_alojamiento');
   ejec('DROP ROLE rol_gerente');
   ejec('DROP ROLE rol_auditor');
END;
/

-- =====================================================================
-- 1. VISTAS DE ÁMBITO POR ALOJAMIENTO
-- =====================================================================
-- Todas usan el mismo filtro: el alojamiento del USUARIO_SISTEMA cuyo
-- username coincide con el usuario de BD conectado. Un usuario sin fila
-- (o inactivo) no ve nada: el valor por defecto es "cerrado".
--
-- Por qué SESSION_USER y no USER ni CURRENT_USER: dentro de una vista o
-- un procedimiento de derechos de definidor, CURRENT_USER es el DUEÑO
-- (TURISMO_UQ). SESSION_USER es siempre quien inició sesión.
-- ---------------------------------------------------------------------

-- 1.1 Reservas del alojamiento: lo que recepción ve en el mostrador.
--     Columnas operativas (quién llega, cuándo, cuántos, cuánto debe).
--     id_cliente se expone porque recepción lo necesita para registrarle
--     una nueva reserva a un huésped que regresa (pkg_transacciones).
--     NO expone: fecha de nacimiento, país/ciudad de origen ni nada de
--     otros alojamientos.
CREATE OR REPLACE VIEW v_recepcion_reservas AS
SELECT r.id_reserva,
       r.id_alojamiento,
       r.id_cliente,
       c.tipo_documento,
       c.numero_documento,
       c.nombres || ' ' || c.apellidos                       AS cliente,
       c.telefono,
       c.email,
       r.fecha_checkin,
       r.fecha_checkout,
       r.fecha_checkout - r.fecha_checkin                    AS noches,
       r.num_huespedes,
       r.estado,
       r.canal,
       (SELECT LISTAGG(h.numero, ', ') WITHIN GROUP (ORDER BY h.numero)
          FROM reserva_habitacion rh
          JOIN habitacion h ON h.id_habitacion = rh.id_habitacion
         WHERE rh.id_reserva = r.id_reserva)                 AS habitaciones,
       r.valor_total,
       r.valor_total - NVL((SELECT SUM(p.valor) FROM pago p
                             WHERE p.id_reserva = r.id_reserva
                               AND p.estado = 'APROBADO'), 0) AS saldo_pendiente
  FROM reserva r
  JOIN cliente c ON c.id_cliente = r.id_cliente
 WHERE r.id_alojamiento = (SELECT us.id_alojamiento
                             FROM usuario_sistema us
                            WHERE UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER')
                              AND us.activo = 'S');

COMMENT ON TABLE v_recepcion_reservas IS
   'Entrega 3 · Recepción: reservas de SU alojamiento (filtro por SESSION_USER)';

-- 1.2 Habitaciones del alojamiento y su ocupación de hoy.
CREATE OR REPLACE VIEW v_recepcion_habitaciones AS
SELECT h.id_habitacion,
       h.id_alojamiento,
       h.numero,
       h.categoria,
       h.capacidad,
       h.activa,
       CASE WHEN EXISTS (SELECT 1
                           FROM reserva_habitacion rh
                           JOIN reserva r ON r.id_reserva = rh.id_reserva
                          WHERE rh.id_habitacion = h.id_habitacion
                            AND r.estado IN ('CONFIRMADA', 'COMPLETADA', 'PENDIENTE')
                            AND r.fecha_checkin  <= TRUNC(SYSDATE)
                            AND r.fecha_checkout >  TRUNC(SYSDATE))
            THEN 'S' ELSE 'N' END                            AS ocupada_hoy,
       (SELECT MIN(r.fecha_checkin)
          FROM reserva_habitacion rh
          JOIN reserva r ON r.id_reserva = rh.id_reserva
         WHERE rh.id_habitacion = h.id_habitacion
           AND r.estado <> 'CANCELADA'
           AND r.fecha_checkin > TRUNC(SYSDATE))             AS proxima_llegada
  FROM habitacion h
 WHERE h.id_alojamiento = (SELECT us.id_alojamiento
                             FROM usuario_sistema us
                            WHERE UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER')
                              AND us.activo = 'S');

COMMENT ON TABLE v_recepcion_habitaciones IS
   'Entrega 3 · Recepción: habitaciones de SU alojamiento y ocupación de hoy';

-- 1.3 Tarifas del alojamiento, ACTUALIZABLE por el administrador.
--     Vista sobre una sola tabla -> Oracle la deja actualizar.
--     WITH CHECK OPTION impide que un UPDATE "saque" la fila del ámbito
--     (p. ej. cambiarle el id_alojamiento a uno ajeno).
--     Cada UPDATE dispara trg_tarifa_auditoria (Entrega 2), que registra
--     al ADMIN conectado como autor del cambio.
CREATE OR REPLACE VIEW v_admin_tarifas AS
SELECT t.id_tarifa, t.id_alojamiento, t.categoria, t.id_temporada, t.valor_noche
  FROM tarifa t
 WHERE t.id_alojamiento = (SELECT us.id_alojamiento
                             FROM usuario_sistema us
                            WHERE UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER')
                              AND us.activo = 'S')
  WITH CHECK OPTION CONSTRAINT ck_v_admin_tarifas;

-- 1.4 Habitaciones actualizables (activar / desactivar por mantenimiento).
CREATE OR REPLACE VIEW v_admin_habitaciones AS
SELECT h.id_habitacion, h.id_alojamiento, h.numero, h.categoria, h.capacidad, h.activa
  FROM habitacion h
 WHERE h.id_alojamiento = (SELECT us.id_alojamiento
                             FROM usuario_sistema us
                            WHERE UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER')
                              AND us.activo = 'S')
  WITH CHECK OPTION CONSTRAINT ck_v_admin_habitaciones;

-- 1.5 Ingresos mensuales del alojamiento (lo que liquida el administrador).
CREATE OR REPLACE VIEW v_admin_ingresos_mes AS
SELECT r.id_alojamiento,
       TO_CHAR(r.fecha_checkout, 'YYYY-MM')                  AS anio_mes,
       COUNT(*)                                              AS reservas,
       SUM(r.valor_alojamiento)                              AS valor_alojamiento,
       SUM(r.valor_servicios)                                AS valor_servicios,
       SUM(r.valor_total)                                    AS valor_total,
       SUM(NVL((SELECT SUM(p.valor) FROM pago p
                 WHERE p.id_reserva = r.id_reserva AND p.estado = 'APROBADO'), 0)) AS pagado
  FROM reserva r
 WHERE r.estado IN ('CONFIRMADA', 'COMPLETADA')
   AND r.id_alojamiento = (SELECT us.id_alojamiento
                             FROM usuario_sistema us
                            WHERE UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER')
                              AND us.activo = 'S')
 GROUP BY r.id_alojamiento, TO_CHAR(r.fecha_checkout, 'YYYY-MM');


-- =====================================================================
-- 2. ROLES Y PRIVILEGIOS
-- =====================================================================
-- Principio de mínimo privilegio. Matriz completa en
-- docs/DOCUMENTACION_ENTREGA3.md (FASE 5).
-- ---------------------------------------------------------------------
CREATE ROLE rol_recepcion;
CREATE ROLE rol_admin_alojamiento;
CREATE ROLE rol_gerente;
CREATE ROLE rol_auditor;

-- Privilegio de SISTEMA común: poder conectarse. Nada más de sistema:
-- ningún rol puede crear objetos.
GRANT CREATE SESSION TO rol_recepcion, rol_admin_alojamiento, rol_gerente, rol_auditor;

-- ---------- RECEPCIÓN: solo vistas + el paquete transaccional ----------
-- Lectura únicamente por VISTAS de su alojamiento. Para escribir (crear una
-- reserva con su pago) usa el PROCEDIMIENTO, nunca un INSERT: el paquete
-- corre con derechos del dueño, valida disponibilidad, bloquea la
-- habitación y verifica que el alojamiento sea el suyo (-20020).
GRANT SELECT  ON v_recepcion_reservas     TO rol_recepcion;
GRANT SELECT  ON v_recepcion_habitaciones TO rol_recepcion;
GRANT EXECUTE ON pkg_transacciones        TO rol_recepcion;

-- ---------- ADMINISTRADOR DE ALOJAMIENTO ----------
-- Hereda todo lo de recepción (jerarquía de roles) y además gestiona
-- precios y habitaciones de SU alojamiento, también por vistas.
GRANT rol_recepcion TO rol_admin_alojamiento;
GRANT SELECT, UPDATE (valor_noche) ON v_admin_tarifas      TO rol_admin_alojamiento;
GRANT SELECT, UPDATE (activa)      ON v_admin_habitaciones TO rol_admin_alojamiento;
GRANT SELECT                       ON v_admin_ingresos_mes TO rol_admin_alojamiento;

-- ---------- GERENTE: lectura transversal del negocio ----------
-- Ve todo el departamento para analizar (las 8 consultas, la MV), pero
-- no modifica nada y no ve la auditoría (separación de funciones: quien es
-- auditado no controla la evidencia). Puede correr la liquidación mensual.
BEGIN
   FOR t IN (SELECT object_name FROM user_objects
              WHERE object_name IN ('MUNICIPIO', 'TIPO_ALOJAMIENTO', 'CATEGORIA_HABITACION',
                                    'ALOJAMIENTO', 'HABITACION', 'TEMPORADA', 'TARIFA',
                                    'DIM_TIEMPO', 'CLIENTE', 'SERVICIO', 'RESERVA',
                                    'RESERVA_HABITACION', 'PAGO', 'RESERVA_SERVICIO', 'RESENA',
                                    'V_NOCHE_VENDIDA', 'V_INVENTARIO_NOCHE',
                                    'MV_OCUPACION_MENSUAL')
                AND object_type IN ('TABLE', 'VIEW')) LOOP
      EXECUTE IMMEDIATE 'GRANT SELECT ON ' || t.object_name || ' TO rol_gerente';
   END LOOP;
END;
/
GRANT EXECUTE ON pkg_turismo TO rol_gerente;

-- ---------- AUDITOR: la evidencia, solo lectura ----------
-- Lo que un auditor revisa: cambios de precio, cobros, reservas y quién
-- tiene cuenta en la plataforma. NO ve datos personales de los clientes
-- (CLIENTE) ni puede ejecutar procesos.
GRANT SELECT ON auditoria_tarifa TO rol_auditor;
GRANT SELECT ON tarifa           TO rol_auditor;
GRANT SELECT ON pago             TO rol_auditor;
GRANT SELECT ON reserva          TO rol_auditor;
GRANT SELECT ON usuario_sistema  TO rol_auditor;


-- =====================================================================
-- 3. PERFIL CON LÍMITES DE SESIÓN
-- =====================================================================
-- Un perfil limita RECURSOS y CONTRASEÑAS; un rol, PRIVILEGIOS. Son
-- independientes: un usuario tiene un perfil y uno o varios roles.
--
-- Límites elegidos para el personal de la plataforma:
--   SESSIONS_PER_USER     2   un puesto de recepción no necesita más; impide
--                             compartir la cuenta entre varios equipos
--   IDLE_TIME            15   minutos inactivo -> Oracle cierra la sesión
--                             (equipo de mostrador desatendido)
--   CONNECT_TIME        600   minutos (10 h): un turno, como máximo
--   LOGICAL_READS_PER_CALL 200000  freno a una consulta desbocada (la más
--                             pesada del proyecto lee ~ 2.000 bloques)
--   FAILED_LOGIN_ATTEMPTS 5   y PASSWORD_LOCK_TIME 1/96 (15 min de bloqueo)
--   PASSWORD_LIFE_TIME   90   días, con 7 de gracia
-- Los límites de recursos solo se aplican con RESOURCE_LIMIT = TRUE
-- (lo fija 13_privilegios_entrega3.sql).
-- ---------------------------------------------------------------------
CREATE PROFILE perfil_turismo_operativo LIMIT
   SESSIONS_PER_USER        2
   IDLE_TIME                15
   CONNECT_TIME             600
   LOGICAL_READS_PER_CALL   200000
   FAILED_LOGIN_ATTEMPTS    5
   PASSWORD_LOCK_TIME       1/96
   PASSWORD_LIFE_TIME       90
   PASSWORD_GRACE_TIME      7;


-- =====================================================================
-- 4. USUARIOS DE DEMOSTRACIÓN
-- =====================================================================
-- Uno por rol, con el mismo nombre que su fila en USUARIO_SISTEMA (de ahí
-- sale su alojamiento). RECEP2 existe para demostrar que la MISMA vista
-- devuelve filas distintas según quién se conecte.
-- Contraseña común de demostración: Demo_UQ2026 (ver nota de credenciales
-- en el README: aceptable en un proyecto académico, no en producción).
-- ---------------------------------------------------------------------
CREATE USER recep1   IDENTIFIED BY "Demo_UQ2026" PROFILE perfil_turismo_operativo;
CREATE USER recep2   IDENTIFIED BY "Demo_UQ2026" PROFILE perfil_turismo_operativo;
CREATE USER admin1   IDENTIFIED BY "Demo_UQ2026" PROFILE perfil_turismo_operativo;
CREATE USER gerente1 IDENTIFIED BY "Demo_UQ2026" PROFILE perfil_turismo_operativo;
CREATE USER auditor1 IDENTIFIED BY "Demo_UQ2026" PROFILE perfil_turismo_operativo;

GRANT rol_recepcion         TO recep1, recep2;
GRANT rol_admin_alojamiento TO admin1;
GRANT rol_gerente           TO gerente1;
GRANT rol_auditor           TO auditor1;


-- =====================================================================
-- 5. VERIFICACIÓN DESDE EL DICCIONARIO
-- =====================================================================
SET ECHO OFF

PROMPT
PROMPT === Privilegios de objeto por rol ===
SELECT p.grantee AS rol, o.object_type AS tipo, p.table_name AS objeto, p.privilege
  FROM user_tab_privs_made p
  JOIN user_objects o ON o.object_name = p.table_name
                     AND o.object_type IN ('TABLE', 'VIEW', 'PACKAGE', 'MATERIALIZED VIEW')
 WHERE p.grantee LIKE 'ROL\_%' ESCAPE '\'
 ORDER BY p.grantee, o.object_type, p.table_name, p.privilege;

PROMPT === Columnas actualizables del administrador ===
SELECT grantee AS rol, table_name AS vista, column_name AS columna, privilege
  FROM user_col_privs_made
 WHERE grantee LIKE 'ROL\_%' ESCAPE '\'
 ORDER BY grantee, table_name;

PROMPT === Requisito: recepción NO tiene ningún privilegio sobre tablas (debe dar 0) ===
SELECT COUNT(*) AS privilegios_sobre_tablas
  FROM user_tab_privs_made p
  JOIN user_tables t ON t.table_name = p.table_name
 WHERE p.grantee = 'ROL_RECEPCION';

PROMPT === Roles asignados a cada usuario de demostración ===
SELECT grantee AS usuario, granted_role AS rol
  FROM dba_role_privs
 WHERE grantee IN ('RECEP1', 'RECEP2', 'ADMIN1', 'GERENTE1', 'AUDITOR1')
    OR (grantee LIKE 'ROL\_%' ESCAPE '\' AND granted_role LIKE 'ROL\_%' ESCAPE '\')
 ORDER BY grantee;

PROMPT === Perfil y sus límites ===
SELECT resource_name, resource_type, limit
  FROM dba_profiles
 WHERE profile = 'PERFIL_TURISMO_OPERATIVO'
   AND limit NOT IN ('DEFAULT')
 ORDER BY resource_type, resource_name;

SELECT username, profile, account_status
  FROM dba_users
 WHERE username IN ('RECEP1', 'RECEP2', 'ADMIN1', 'GERENTE1', 'AUDITOR1')
 ORDER BY username;
