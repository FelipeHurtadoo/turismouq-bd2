-- =====================================================================
-- TurismoUQ · 13_privilegios_entrega3.sql
-- Ejecutar como:  SYS AS SYSDBA  conectado al PDB XEPDB1
--   sqlplus sys/<password>@localhost:1521/XEPDB1 as sysdba
--
-- Entrega 3 · Privilegios de sistema adicionales para TURISMO_UQ.
--
-- El script 01 ya otorgó CREATE ROLE, CREATE USER, CREATE PROFILE,
-- ALTER USER y CREATE JOB pensando en esta entrega. Faltan los privilegios
-- que hacen REPETIBLE el script de seguridad (borrar y volver a crear los
-- usuarios y el perfil de demostración) y las vistas dinámicas que usan los
-- scripts de concurrencia e índices dentro de PL/SQL.
--
-- Por qué GRANT directo y no basta SELECT_CATALOG_ROLE: los roles NO están
-- activos dentro de un procedimiento almacenado con derechos de definidor.
-- Un GRANT directo sobre V_$... funciona en cualquier contexto.
--
-- Es idempotente: re-otorgar un privilegio que ya se tiene no da error.
-- =====================================================================

SET ECHO ON

-- Si se conectó al CDB raíz (XE), descomente la línea siguiente.
-- ALTER SESSION SET CONTAINER = XEPDB1;

PROMPT === Contenedor actual (debe ser XEPDB1) ===
SELECT SYS_CONTEXT('USERENV','CON_NAME') AS contenedor FROM dual;

-- Seguridad (18_seguridad.sql). WITH ADMIN OPTION es lo que le permite a
-- TURISMO_UQ pasarle CREATE SESSION a los roles: sin él, puede conectarse
-- pero no puede otorgar a otros el derecho a conectarse.
GRANT CREATE SESSION  TO turismo_uq WITH ADMIN OPTION;
-- Re-ejecución limpia de usuarios y perfil de demostración
GRANT DROP USER       TO turismo_uq;
GRANT ALTER PROFILE   TO turismo_uq;
GRANT DROP PROFILE    TO turismo_uq;

-- Concurrencia (16_concurrencia.sql): ver quién bloquea a quién
GRANT SELECT ON sys.v_$session   TO turismo_uq;
GRANT SELECT ON sys.v_$lock      TO turismo_uq;
GRANT SELECT ON sys.v_$locked_object TO turismo_uq;

-- Índices (17_indices.sql): medir lecturas lógicas de la propia sesión
GRANT SELECT ON sys.v_$mystat    TO turismo_uq;
GRANT SELECT ON sys.v_$statname  TO turismo_uq;
GRANT SELECT ON sys.v_$sql_plan  TO turismo_uq;
GRANT SELECT ON sys.v_$sql_plan_statistics_all TO turismo_uq;

-- Perfil (18_seguridad.sql): los límites de recursos (SESSIONS_PER_USER,
-- IDLE_TIME, CONNECT_TIME) solo se hacen cumplir si RESOURCE_LIMIT = TRUE.
-- En 21c ya es el valor por defecto; se fija explícitamente para no
-- depender de eso.
ALTER SYSTEM SET resource_limit = TRUE SCOPE = BOTH;

PROMPT === Privilegios de sistema de TURISMO_UQ ===
SELECT privilege
  FROM dba_sys_privs
 WHERE grantee = 'TURISMO_UQ'
 ORDER BY privilege;

PROMPT === resource_limit (debe ser TRUE) ===
SELECT value FROM v$parameter WHERE name = 'resource_limit';
