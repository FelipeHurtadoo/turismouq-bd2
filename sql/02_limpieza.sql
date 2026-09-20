-- =====================================================================
-- TurismoUQ · 02_limpieza.sql
-- Ejecutar como: TURISMO_UQ
-- Deja el esquema vacío. Permite re-ejecutar 03..09 tantas veces como
-- haga falta sin errores "name is already used by an existing object".
-- =====================================================================

SET SERVEROUTPUT ON
SET ECHO OFF

DECLARE
   PROCEDURE ejec(p_sql VARCHAR2) IS
   BEGIN
      EXECUTE IMMEDIATE p_sql;
   EXCEPTION WHEN OTHERS THEN
      NULL;   -- el objeto no existía: es lo esperado en base limpia
   END;
BEGIN
   -- 1) Vistas materializadas
   FOR r IN (SELECT mview_name FROM user_mviews) LOOP
      ejec('DROP MATERIALIZED VIEW ' || r.mview_name);
   END LOOP;

   -- 2) Logs de vista materializada (si llegaran a existir)
   FOR r IN (SELECT master FROM user_mview_logs) LOOP
      ejec('DROP MATERIALIZED VIEW LOG ON ' || r.master);
   END LOOP;

   -- 3) Vistas
   FOR r IN (SELECT view_name FROM user_views) LOOP
      ejec('DROP VIEW ' || r.view_name);
   END LOOP;

   -- 4) Tablas (CASCADE CONSTRAINTS resuelve el orden de las FK)
   FOR r IN (SELECT table_name FROM user_tables WHERE nested = 'NO') LOOP
      ejec('DROP TABLE ' || r.table_name || ' CASCADE CONSTRAINTS PURGE');
   END LOOP;

   -- 5) Secuencias
   FOR r IN (SELECT sequence_name FROM user_sequences) LOOP
      ejec('DROP SEQUENCE ' || r.sequence_name);
   END LOOP;

   -- 6) Programas PL/SQL (relevante a partir de la Entrega 2)
   FOR r IN (SELECT object_name, object_type FROM user_objects
              WHERE object_type IN ('PACKAGE','PROCEDURE','FUNCTION','TYPE')) LOOP
      ejec('DROP ' || r.object_type || ' ' || r.object_name);
   END LOOP;

   DBMS_OUTPUT.PUT_LINE('Esquema TURISMO_UQ limpio.');
END;
/

PURGE RECYCLEBIN;

SELECT COUNT(*) AS objetos_restantes FROM user_objects;
