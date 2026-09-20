-- =====================================================================
-- TurismoUQ · 01_tablespaces_usuario.sql
-- Ejecutar como:  SYS AS SYSDBA  conectado al PDB XEPDB1
--   sqlplus sys/<password>@localhost:1521/XEPDB1 as sysdba
-- Requisito del documento: "Un tablespace propio para el histórico de reservas".
-- Decisión de diseño: se crean TRES tablespaces (catálogo / histórico / índices).
-- =====================================================================

SET ECHO ON
SET SERVEROUTPUT ON

-- Si se conectó al CDB raíz (XE), descomente la línea siguiente.
-- ALTER SESSION SET CONTAINER = XEPDB1;

PROMPT === Contenedor actual (debe ser XEPDB1) ===
SELECT SYS_CONTEXT('USERENV','CON_NAME') AS contenedor FROM dual;

-- ---------------------------------------------------------------------
-- Limpieza previa (permite re-ejecución en base limpia)
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
   ejec('DROP USER turismo_uq CASCADE');
   ejec('DROP TABLESPACE ts_turismo_hist INCLUDING CONTENTS AND DATAFILES');
   ejec('DROP TABLESPACE ts_turismo_idx  INCLUDING CONTENTS AND DATAFILES');
   ejec('DROP TABLESPACE ts_turismo_dat  INCLUDING CONTENTS AND DATAFILES');
END;
/

-- ---------------------------------------------------------------------
-- Ruta de los datafiles
-- ---------------------------------------------------------------------
-- Verifique dónde guarda datafiles su instalación:
--    SELECT name FROM v$datafile;
-- Linux (típico XE 21c):  /opt/oracle/oradata/XE/XEPDB1/
-- Windows (típico):       C:\app\<usuario>\product\21c\oradata\XE\XEPDB1\
-- Si el parámetro DB_CREATE_FILE_DEST está configurado, puede omitir la
-- cláusula DATAFILE por completo y Oracle usará OMF.
-- Ajuste las rutas de abajo antes de ejecutar.

-- === 1) Tablespace de CATÁLOGO (datos maestros, poco volumen, alta lectura) ===
CREATE TABLESPACE ts_turismo_dat
   DATAFILE '/opt/oracle/oradata/XE/XEPDB1/ts_turismo_dat01.dbf'
   SIZE 100M AUTOEXTEND ON NEXT 25M MAXSIZE 2G
   EXTENT MANAGEMENT LOCAL AUTOALLOCATE
   SEGMENT SPACE MANAGEMENT AUTO;

-- === 2) Tablespace HISTÓRICO DE RESERVAS (requisito del documento) ===
--     Aloja el hecho transaccional y sus hijos: RESERVA, RESERVA_HABITACION,
--     PAGO, RESERVA_SERVICIO, RESENA, AUDITORIA_TARIFA.
--     Es el 95 % de las filas y el 100 % del crecimiento del sistema.
CREATE TABLESPACE ts_turismo_hist
   DATAFILE '/opt/oracle/oradata/XE/XEPDB1/ts_turismo_hist01.dbf'
   SIZE 300M AUTOEXTEND ON NEXT 50M MAXSIZE 6G
   EXTENT MANAGEMENT LOCAL AUTOALLOCATE
   SEGMENT SPACE MANAGEMENT AUTO;

-- === 3) Tablespace de ÍNDICES ===
--     Separar índices de datos evita que el crecimiento de uno fragmente al otro
--     y permite medir por separado el costo en disco de la Entrega 3.
CREATE TABLESPACE ts_turismo_idx
   DATAFILE '/opt/oracle/oradata/XE/XEPDB1/ts_turismo_idx01.dbf'
   SIZE 100M AUTOEXTEND ON NEXT 25M MAXSIZE 3G
   EXTENT MANAGEMENT LOCAL AUTOALLOCATE
   SEGMENT SPACE MANAGEMENT AUTO;

-- ---------------------------------------------------------------------
-- Usuario / esquema del proyecto
-- ---------------------------------------------------------------------
CREATE USER turismo_uq IDENTIFIED BY "TurismoUQ_2026"
   DEFAULT TABLESPACE ts_turismo_dat
   TEMPORARY TABLESPACE temp;

-- Sin QUOTA el usuario NO puede escribir en un tablespace, aunque tenga
-- privilegio CREATE TABLE. Es el error más común de este punto.
ALTER USER turismo_uq QUOTA UNLIMITED ON ts_turismo_dat;
ALTER USER turismo_uq QUOTA UNLIMITED ON ts_turismo_hist;
ALTER USER turismo_uq QUOTA UNLIMITED ON ts_turismo_idx;

GRANT CREATE SESSION            TO turismo_uq;
GRANT CREATE TABLE              TO turismo_uq;
GRANT CREATE VIEW               TO turismo_uq;
GRANT CREATE SEQUENCE           TO turismo_uq;
GRANT CREATE PROCEDURE          TO turismo_uq;   -- Entrega 2
GRANT CREATE TRIGGER            TO turismo_uq;   -- Entrega 2
GRANT CREATE TYPE               TO turismo_uq;
GRANT CREATE SYNONYM            TO turismo_uq;
GRANT CREATE MATERIALIZED VIEW  TO turismo_uq;   -- Consulta 6
GRANT CREATE JOB                TO turismo_uq;   -- refresco programado de la MV
GRANT CREATE ROLE               TO turismo_uq;   -- Entrega 3 (roles)
GRANT CREATE USER               TO turismo_uq;   -- Entrega 3 (usuarios de rol)
GRANT CREATE PROFILE            TO turismo_uq;   -- Entrega 3 (perfil de sesión)
GRANT ALTER USER                TO turismo_uq;   -- Entrega 3 (asignar perfil)

-- Para ver planes de ejecución y estadísticas en la Entrega 3
GRANT SELECT_CATALOG_ROLE       TO turismo_uq;
GRANT SELECT ON sys.v_$session  TO turismo_uq;
GRANT SELECT ON sys.v_$sql      TO turismo_uq;
GRANT SELECT ON sys.v_$lock     TO turismo_uq;

PROMPT === Tablespaces creados ===
SELECT tablespace_name, status, contents
  FROM dba_tablespaces
 WHERE tablespace_name LIKE 'TS_TURISMO%';

PROMPT === Cuotas del usuario ===
SELECT tablespace_name, max_bytes
  FROM dba_ts_quotas
 WHERE username = 'TURISMO_UQ';

-- ---------------------------------------------------------------------
-- NOTA SOBRE ORACLE XE 21c
-- ---------------------------------------------------------------------
-- XE limita el volumen de datos de usuario a 12 GB, 2 GB de SGA y 2 hilos de CPU.
-- El proyecto completo ocupa aproximadamente 250–400 MB, muy por debajo del límite.
-- MAXSIZE de los datafiles está acotado a propósito para que un error en el
-- generador de datos no llene el disco.
-- ---------------------------------------------------------------------
