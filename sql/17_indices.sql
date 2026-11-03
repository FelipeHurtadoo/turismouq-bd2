-- =====================================================================
-- TurismoUQ · 17_indices.sql
-- Ejecutar como: TURISMO_UQ   (después de 13_privilegios_entrega3.sql)
--
-- Entrega 3 · Índices. Para cada una de 3 consultas lentas:
--     plan ANTES -> medición ANTES -> CREATE INDEX -> plan DESPUÉS -> medición DESPUÉS
--   Q1 · agenda de llegadas de un alojamiento   -> índice COMPUESTO
--   Q2 · buscar un cliente por correo           -> índice BASADO EN FUNCIÓN
--   Q3 · historial de reservas de un cliente    -> índice sobre FK sin indexar
--   Q4 · caso donde el índice NO ayuda (estado de la reserva, baja selectividad)
--   Q5 · caso límite: índice por función sobre el mes, que el optimizador
--        descarta por el clustering factor
--
-- Qué se mide (PKG_MEDICION, creado aquí):
--   · LECTURAS LÓGICAS por ejecución ("session logical reads" de V$MYSTAT):
--     bloques que la consulta tuvo que tocar. Es la métrica que importa:
--     no depende de si el bloque estaba en caché ni de la carga del equipo.
--   · Tiempo medio por ejecución (100 repeticiones), como dato secundario.
--   · El plan es el de EXPLAIN PLAN + DBMS_XPLAN (operación, filas, costo,
--     predicados de acceso y de filtro).
--
-- Re-ejecutable: al empezar borra los índices de esta entrega, así que
-- cada corrida vuelve a medir el "antes" de verdad. Las consultas usan
-- literales (no binds) para que EXPLAIN PLAN y la ejecución vean el mismo
-- valor y el plan mostrado sea el que se mide.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO OFF
SET LINESIZE 200

-- =====================================================================
-- Utilidad de medición. Se deja en el esquema a propósito: en la
-- sustentación permite medir EN VIVO cualquier consulta que se pida:
--    EXEC pkg_medicion.plan('SELECT ...');
--    EXEC pkg_medicion.medir('etiqueta', 'SELECT ...');
-- =====================================================================
CREATE OR REPLACE PACKAGE pkg_medicion AUTHID CURRENT_USER AS
   -- Imprime el plan estimado de p_sql (EXPLAIN PLAN + DBMS_XPLAN.DISPLAY).
   PROCEDURE plan(p_sql IN VARCHAR2);
   -- Ejecuta p_sql p_reps veces trayendo TODAS las filas y guarda/imprime
   -- lecturas lógicas y milisegundos por ejecución.
   PROCEDURE medir(p_etiqueta IN VARCHAR2, p_sql IN VARCHAR2, p_reps IN PLS_INTEGER DEFAULT 100);
   -- Tabla comparativa de todo lo medido en esta sesión.
   PROCEDURE resumen;
   PROCEDURE limpiar;
END pkg_medicion;
/

CREATE OR REPLACE PACKAGE BODY pkg_medicion AS

   TYPE t_medida IS RECORD (etiqueta VARCHAR2(60), gets NUMBER, ms NUMBER, filas NUMBER);
   TYPE t_medidas IS TABLE OF t_medida INDEX BY PLS_INTEGER;
   g_medidas t_medidas;

   FUNCTION lecturas_logicas RETURN NUMBER IS
      v NUMBER;
   BEGIN
      SELECT m.value INTO v
        FROM v$mystat m JOIN v$statname n ON n.statistic# = m.statistic#
       WHERE n.name = 'session logical reads';
      RETURN v;
   END;

   PROCEDURE plan(p_sql IN VARCHAR2) IS
      v_id VARCHAR2(30) := 'E3_' || TO_CHAR(SYSTIMESTAMP, 'HH24MISSFF3');
   BEGIN
      EXECUTE IMMEDIATE 'EXPLAIN PLAN SET STATEMENT_ID = ''' || v_id || ''' FOR ' || p_sql;
      FOR r IN (SELECT plan_table_output AS linea
                  FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', v_id, 'BASIC +ROWS +COST +PREDICATE'))) LOOP
         IF r.linea NOT LIKE 'Plan hash value%' AND TRIM(r.linea) IS NOT NULL THEN
            DBMS_OUTPUT.PUT_LINE('   ' || r.linea);
         END IF;
      END LOOP;
      DELETE FROM plan_table WHERE statement_id = v_id;
   END plan;

   PROCEDURE medir(p_etiqueta IN VARCHAR2, p_sql IN VARCHAR2, p_reps IN PLS_INTEGER DEFAULT 100) IS
      v_cur   INTEGER;
      v_dummy INTEGER;
      v_filas NUMBER := 0;
      v_g0    NUMBER;
      v_t0    PLS_INTEGER;
      v_m     t_medida;
   BEGIN
      -- DBMS_SQL permite traer todas las filas de una consulta cualquiera
      -- sin conocer sus columnas: se mide la consulta tal cual, completa,
      -- no un COUNT(*) que el optimizador podría resolver con otro plan.
      v_cur := DBMS_SQL.OPEN_CURSOR;
      DBMS_SQL.PARSE(v_cur, p_sql, DBMS_SQL.NATIVE);

      v_dummy := DBMS_SQL.EXECUTE(v_cur);            -- calentamiento (parse, caché)
      WHILE DBMS_SQL.FETCH_ROWS(v_cur) > 0 LOOP NULL; END LOOP;

      v_g0 := lecturas_logicas;
      v_t0 := DBMS_UTILITY.GET_TIME;
      FOR i IN 1 .. p_reps LOOP
         v_dummy := DBMS_SQL.EXECUTE(v_cur);
         WHILE DBMS_SQL.FETCH_ROWS(v_cur) > 0 LOOP
            v_filas := v_filas + 1;
         END LOOP;
      END LOOP;
      v_m.ms    := (DBMS_UTILITY.GET_TIME - v_t0) * 10 / p_reps;
      v_m.gets  := (lecturas_logicas - v_g0) / p_reps;
      v_m.filas := v_filas / p_reps;
      v_m.etiqueta := p_etiqueta;
      DBMS_SQL.CLOSE_CURSOR(v_cur);

      g_medidas(g_medidas.COUNT + 1) := v_m;
      DBMS_OUTPUT.PUT_LINE('   >> ' || RPAD(p_etiqueta, 40) ||
         ' lecturas lógicas/ejec = ' || LPAD(TO_CHAR(ROUND(v_m.gets)), 6) ||
         ' · ms/ejec = ' || LPAD(TO_CHAR(v_m.ms, 'FM9990.00'), 7) ||
         ' · filas = ' || v_m.filas);
   EXCEPTION
      WHEN OTHERS THEN
         IF DBMS_SQL.IS_OPEN(v_cur) THEN DBMS_SQL.CLOSE_CURSOR(v_cur); END IF;
         RAISE;
   END medir;

   PROCEDURE resumen IS
   BEGIN
      DBMS_OUTPUT.PUT_LINE(RPAD('Medición', 42) || LPAD('lecturas/ejec', 14) ||
                           LPAD('ms/ejec', 10) || LPAD('filas', 8));
      DBMS_OUTPUT.PUT_LINE(RPAD('-', 74, '-'));
      FOR i IN 1 .. g_medidas.COUNT LOOP
         DBMS_OUTPUT.PUT_LINE(RPAD(g_medidas(i).etiqueta, 42) ||
            LPAD(TO_CHAR(ROUND(g_medidas(i).gets)), 14) ||
            LPAD(TO_CHAR(g_medidas(i).ms, 'FM9990.00'), 10) ||
            LPAD(TO_CHAR(g_medidas(i).filas), 8));
      END LOOP;
   END resumen;

   PROCEDURE limpiar IS
   BEGIN
      g_medidas.DELETE;
   END limpiar;

END pkg_medicion;
/

SHOW ERRORS PACKAGE BODY pkg_medicion


PROMPT
PROMPT ############ 0. Punto de partida: sin los índices de esta entrega ############

BEGIN
   FOR i IN (SELECT index_name FROM user_indexes
              WHERE index_name IN ('IX_RESERVA_ALOJ_CHECKIN', 'IX_CLIENTE_EMAIL_UPPER',
                                   'IX_RESERVA_CLIENTE', 'IX_RESERVA_ESTADO',
                                   'IX_RESERVA_MES_CHECKIN')) LOOP
      EXECUTE IMMEDIATE 'DROP INDEX ' || i.index_name;
      DBMS_OUTPUT.PUT_LINE('Índice previo eliminado: ' || i.index_name);
   END LOOP;
   pkg_medicion.limpiar;

   -- Estadísticas frescas: sin ellas el optimizador decide a ciegas y la
   -- comparación no vale. SIZE AUTO deja el histograma de ESTADO, que es lo
   -- que le permite saber que COMPLETADA es ~80 % y PENDIENTE ~1 % (Q4).
   DBMS_STATS.GATHER_TABLE_STATS(USER, 'RESERVA', method_opt => 'FOR ALL COLUMNS SIZE AUTO',
                                 cascade => TRUE);
   DBMS_STATS.GATHER_TABLE_STATS(USER, 'CLIENTE', cascade => TRUE);
END;
/

PROMPT === RESERVA: tamaño real sobre el que se mide ===
SELECT t.num_rows AS filas, t.blocks AS bloques,
       ROUND(s.bytes / 1024 / 1024, 2) AS mb, t.tablespace_name
  FROM user_tables t JOIN user_segments s ON s.segment_name = t.table_name
 WHERE t.table_name = 'RESERVA';

PROMPT === Distribución de RESERVA.ESTADO (clave del caso Q4) ===
SELECT estado, COUNT(*) AS reservas,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS pct
  FROM reserva GROUP BY estado ORDER BY reservas DESC;


-- =====================================================================
-- Q1 · AGENDA DE LLEGADAS DE UN ALOJAMIENTO  ->  ÍNDICE COMPUESTO
-- =====================================================================
-- La pantalla que recepción abre cada mañana: quién llega a MI hotel en
-- las próximas semanas. Filtra por igualdad (id_alojamiento) y por rango
-- (fecha_checkin), y ordena por fecha.
--
-- Sin índice: TABLE ACCESS FULL sobre las 25.000 reservas para quedarse
-- con unas 20. El FK reserva.id_alojamiento se dejó sin índice a propósito
-- desde la Entrega 1 (bloque 6 de 04_ddl.sql).
--
-- Índice: (id_alojamiento, fecha_checkin), EN ESE ORDEN:
--   · la columna de IGUALDAD va primero y la de RANGO después: así todas
--     las entradas que sirven quedan contiguas en una sola hoja del índice.
--     Al revés, (fecha_checkin, id_alojamiento), el rango de fechas
--     recorrería las llegadas de los 60 alojamientos y filtraría después.
--   · como las entradas ya están ordenadas por fecha dentro del alojamiento,
--     el ORDER BY sale gratis: desaparece el SORT ORDER BY del plan.
--   · por el principio del prefijo izquierdo sirve también para cualquier
--     consulta que filtre solo por id_alojamiento (la FK queda indexada).
-- =====================================================================
PROMPT
PROMPT ############ Q1 · Agenda de llegadas de un alojamiento (índice compuesto) ############

DECLARE
   c_q CONSTANT VARCHAR2(1000) :=
      'SELECT r.id_reserva, r.fecha_checkin, r.fecha_checkout, r.num_huespedes, r.estado, ' ||
      '       c.nombres || '' '' || c.apellidos AS cliente, c.telefono ' ||
      '  FROM reserva r JOIN cliente c ON c.id_cliente = r.id_cliente ' ||
      ' WHERE r.id_alojamiento = 10 ' ||
      '   AND r.fecha_checkin >= DATE ''2025-12-01'' AND r.fecha_checkin < DATE ''2026-01-01'' ' ||
      ' ORDER BY r.fecha_checkin';
BEGIN
   DBMS_OUTPUT.PUT_LINE('--- PLAN ANTES ---');
   pkg_medicion.plan(c_q);
   pkg_medicion.medir('Q1 agenda alojamiento · ANTES', c_q);

   EXECUTE IMMEDIATE 'CREATE INDEX ix_reserva_aloj_checkin ON reserva (id_alojamiento, fecha_checkin) ' ||
                     'TABLESPACE ts_turismo_idx';
   DBMS_OUTPUT.PUT_LINE('*** CREATE INDEX ix_reserva_aloj_checkin ON reserva (id_alojamiento, fecha_checkin)');

   DBMS_OUTPUT.PUT_LINE('--- PLAN DESPUÉS ---');
   pkg_medicion.plan(c_q);
   pkg_medicion.medir('Q1 agenda alojamiento · DESPUÉS', c_q);
END;
/


-- =====================================================================
-- Q2 · BUSCAR UN CLIENTE POR CORREO  ->  ÍNDICE BASADO EN FUNCIÓN
-- =====================================================================
-- Recepción busca al huésped que llega por el correo que él dicta, escrito
-- como venga: "Ana.Perez@Mail.com", "ana.perez@mail.com"... Para no fallar
-- por mayúsculas, la consulta compara UPPER(email) = UPPER(:correo).
--
-- El detalle que hace interesante el caso: CLIENTE YA TIENE un índice sobre
-- email (el UNIQUE uq_cliente_email de la Entrega 1). Y aun así se hace un
-- barrido completo, porque una función aplicada sobre la columna INHABILITA
-- el índice normal: el índice guarda email, no UPPER(email), y el
-- optimizador no puede buscar en él un valor que no contiene.
--
-- Índice basado en función sobre EXACTAMENTE la misma expresión. El
-- predicado pasa de "filter" (revisar fila por fila) a "access" (ir directo).
-- =====================================================================
PROMPT
PROMPT ############ Q2 · Buscar cliente por correo sin distinguir mayúsculas (índice basado en función) ############

DECLARE
   v_correo VARCHAR2(200);
   v_q      VARCHAR2(1000);
BEGIN
   -- El correo de un cliente real, escrito "como lo dicta el huésped".
   SELECT INITCAP(email) INTO v_correo FROM cliente WHERE id_cliente = 1500;
   v_q := 'SELECT c.id_cliente, c.tipo_documento, c.numero_documento, c.nombres, ' ||
          '       c.apellidos, c.telefono, c.email ' ||
          '  FROM cliente c ' ||
          ' WHERE UPPER(c.email) = UPPER(''' || v_correo || ''')';
   DBMS_OUTPUT.PUT_LINE('Correo buscado: ' || v_correo);

   DBMS_OUTPUT.PUT_LINE('--- PLAN ANTES (existe uq_cliente_email, pero no sirve) ---');
   pkg_medicion.plan(v_q);
   pkg_medicion.medir('Q2 cliente por correo · ANTES', v_q);

   EXECUTE IMMEDIATE 'CREATE INDEX ix_cliente_email_upper ON cliente (UPPER(email)) ' ||
                     'TABLESPACE ts_turismo_idx';
   -- Un índice por función crea una columna virtual oculta: se le sacan
   -- estadísticas para que el optimizador conozca su selectividad.
   DBMS_STATS.GATHER_TABLE_STATS(USER, 'CLIENTE', method_opt => 'FOR ALL HIDDEN COLUMNS SIZE 1',
                                 cascade => TRUE);
   DBMS_OUTPUT.PUT_LINE('*** CREATE INDEX ix_cliente_email_upper ON cliente (UPPER(email))');

   DBMS_OUTPUT.PUT_LINE('--- PLAN DESPUÉS ---');
   pkg_medicion.plan(v_q);
   pkg_medicion.medir('Q2 cliente por correo · DESPUÉS', v_q);
END;
/


-- =====================================================================
-- Q3 · HISTORIAL DE UN CLIENTE  ->  ÍNDICE SOBRE LA FK reserva.id_cliente
-- =====================================================================
-- "Muéstreme todas las estadías de este cliente": servicio al cliente lo
-- pide cada vez que alguien llama. Un cliente tiene ~8 reservas de 25.000.
--
-- Sin índice: barrido completo para devolver 8 filas (0,03 % de la tabla).
-- Es la consulta más selectiva de las tres y por eso la de mayor ganancia.
--
-- Efecto secundario que también se corrige: una FK SIN índice hace que un
-- DELETE o un UPDATE de la PK en CLIENTE tenga que bloquear RESERVA entera
-- (bloqueo TM de tabla) mientras busca filas hijas. Con el índice, Oracle
-- solo bloquea las filas hijas afectadas.
-- =====================================================================
PROMPT
PROMPT ############ Q3 · Historial de reservas de un cliente (FK sin indexar) ############

DECLARE
   c_q CONSTANT VARCHAR2(1000) :=
      'SELECT r.id_reserva, a.nombre AS alojamiento, r.fecha_checkin, r.fecha_checkout, ' ||
      '       r.estado, r.valor_total ' ||
      '  FROM reserva r JOIN alojamiento a ON a.id_alojamiento = r.id_alojamiento ' ||
      ' WHERE r.id_cliente = 1500 ' ||
      ' ORDER BY r.fecha_checkin DESC';
BEGIN
   DBMS_OUTPUT.PUT_LINE('--- PLAN ANTES ---');
   pkg_medicion.plan(c_q);
   pkg_medicion.medir('Q3 historial cliente · ANTES', c_q);

   EXECUTE IMMEDIATE 'CREATE INDEX ix_reserva_cliente ON reserva (id_cliente) TABLESPACE ts_turismo_idx';
   DBMS_OUTPUT.PUT_LINE('*** CREATE INDEX ix_reserva_cliente ON reserva (id_cliente)');

   DBMS_OUTPUT.PUT_LINE('--- PLAN DESPUÉS ---');
   pkg_medicion.plan(c_q);
   pkg_medicion.medir('Q3 historial cliente · DESPUÉS', c_q);
END;
/


-- =====================================================================
-- Q4 · EL CASO DONDE EL ÍNDICE NO AYUDA: reserva.estado
-- =====================================================================
-- Reporte: valor de las reservas COMPLETADAS por alojamiento.
-- Intuición equivocada: "filtra por estado, entonces un índice en estado".
--
-- Por qué no ayuda: COMPLETADA es ~80 % de las filas. Un índice B*Tree
-- sirve para encontrar POCAS filas. Para traer el 80 % de la tabla por
-- índice, Oracle tendría que leer la hoja del índice y luego saltar al
-- bloque de la tabla fila por fila (TABLE ACCESS BY INDEX ROWID), visitando
-- los mismos ~250 bloques de RESERVA muchas veces. El barrido completo los
-- lee una sola vez cada uno, en lecturas multibloque. Con el histograma de
-- ESTADO el optimizador lo sabe y DESCARTA el índice por su cuenta.
--
-- La demostración tiene tres partes:
--   a) se crea el índice y el plan sigue siendo TABLE ACCESS FULL;
--   b) se le OBLIGA a usarlo con /*+ INDEX */ y se mide: es PEOR;
--   c) contraste: el mismo índice SÍ sirve para PENDIENTE (~1 %). El
--      índice no es "bueno" o "malo": depende de la selectividad del valor.
-- =====================================================================
PROMPT
PROMPT ############ Q4 · Caso donde el índice NO ayuda (estado, baja selectividad) ############

DECLARE
   c_q CONSTANT VARCHAR2(1000) :=
      'SELECT r.id_alojamiento, COUNT(*) AS reservas, SUM(r.valor_total) AS valor ' ||
      '  FROM reserva r ' ||
      ' WHERE r.estado = ''COMPLETADA'' ' ||
      ' GROUP BY r.id_alojamiento';
   c_q_forzada CONSTANT VARCHAR2(1000) :=
      'SELECT /*+ INDEX(r ix_reserva_estado) */ r.id_alojamiento, COUNT(*) AS reservas, ' ||
      '       SUM(r.valor_total) AS valor ' ||
      '  FROM reserva r ' ||
      ' WHERE r.estado = ''COMPLETADA'' ' ||
      ' GROUP BY r.id_alojamiento';
   c_q_rara CONSTANT VARCHAR2(1000) :=
      'SELECT r.id_alojamiento, COUNT(*) AS reservas, SUM(r.valor_total) AS valor ' ||
      '  FROM reserva r ' ||
      ' WHERE r.estado = ''PENDIENTE'' ' ||
      ' GROUP BY r.id_alojamiento';
BEGIN
   DBMS_OUTPUT.PUT_LINE('--- PLAN ANTES (sin índice) ---');
   pkg_medicion.plan(c_q);
   pkg_medicion.medir('Q4 COMPLETADA · sin índice (FULL)', c_q);

   EXECUTE IMMEDIATE 'CREATE INDEX ix_reserva_estado ON reserva (estado) TABLESPACE ts_turismo_idx';
   DBMS_OUTPUT.PUT_LINE('*** CREATE INDEX ix_reserva_estado ON reserva (estado)');

   DBMS_OUTPUT.PUT_LINE('--- a) PLAN DESPUÉS: el optimizador IGNORA el índice ---');
   pkg_medicion.plan(c_q);
   pkg_medicion.medir('Q4 COMPLETADA · con índice (lo ignora)', c_q);

   DBMS_OUTPUT.PUT_LINE('--- b) PLAN FORZADO con /*+ INDEX */ ---');
   pkg_medicion.plan(c_q_forzada);
   pkg_medicion.medir('Q4 COMPLETADA · índice FORZADO', c_q_forzada);

   DBMS_OUTPUT.PUT_LINE('--- c) Contraste: PENDIENTE (~1 %) con el mismo índice ---');
   pkg_medicion.plan(c_q_rara);
   pkg_medicion.medir('Q4 PENDIENTE · con índice', c_q_rara);
END;
/


-- =====================================================================
-- Q5 · CASO LÍMITE: el índice por función que el optimizador no quiere usar
-- =====================================================================
-- Reporte: reservas y valor por canal de las llegadas de diciembre de 2025,
-- escrito con TRUNC(fecha_checkin, 'MM') = DATE '2025-12-01'.
--
-- Este fue el PRIMER candidato para el índice basado en función, y no
-- funcionó como se esperaba: el mes devuelve ~1.100 filas (4 % de la
-- tabla) y aun así el optimizador prefiere el barrido completo.
-- Razón: el CLUSTERING FACTOR. Las reservas se insertaron en orden de
-- creación, no de llegada, así que las llegadas de diciembre están
-- repartidas en casi todos los ~250 bloques de RESERVA (clustering factor
-- ~7.500, cerca del número de FILAS y lejos del de BLOQUES). Leerlas por
-- índice = visitar casi los mismos bloques que el barrido, pero uno por
-- uno (lecturas de un bloque) en vez de en lecturas multibloque.
--
-- Es un caso LÍMITE y se presenta así: forzado con /*+ INDEX */ ahorra
-- apenas ~9 % de lecturas lógicas (los bloques son casi los mismos) y sí
-- ahorra CPU, porque no evalúa TRUNC sobre las 25.000 filas. Pero con los
-- bloques en disco y no en caché, esas ~220 lecturas de un bloque cada una
-- serían más lentas que ~250 bloques leídos en ráfagas; por eso el modelo
-- de costo (211 contra 69) lo descarta. Conclusión: una buena selectividad
-- no basta; si las filas están dispersas, el índice casi no ahorra trabajo.
-- =====================================================================
PROMPT
PROMPT ############ Q5 · Caso límite: índice por función sobre el mes (clustering factor) ############

DECLARE
   c_q CONSTANT VARCHAR2(1000) :=
      'SELECT r.canal, COUNT(*) AS reservas, SUM(r.num_huespedes) AS huespedes, ' ||
      '       SUM(r.valor_total) AS valor ' ||
      '  FROM reserva r ' ||
      ' WHERE TRUNC(r.fecha_checkin, ''MM'') = DATE ''2025-12-01'' ' ||
      ' GROUP BY r.canal ORDER BY valor DESC';
   c_q_forzada CONSTANT VARCHAR2(1000) :=
      'SELECT /*+ INDEX(r ix_reserva_mes_checkin) */ r.canal, COUNT(*) AS reservas, ' ||
      '       SUM(r.num_huespedes) AS huespedes, SUM(r.valor_total) AS valor ' ||
      '  FROM reserva r ' ||
      ' WHERE TRUNC(r.fecha_checkin, ''MM'') = DATE ''2025-12-01'' ' ||
      ' GROUP BY r.canal ORDER BY valor DESC';
   v_cf     NUMBER;
   v_blq    NUMBER;
   v_filas  NUMBER;
BEGIN
   DBMS_OUTPUT.PUT_LINE('--- PLAN ANTES (sin índice) ---');
   pkg_medicion.plan(c_q);
   pkg_medicion.medir('Q5 llegadas del mes · sin índice', c_q);

   EXECUTE IMMEDIATE 'CREATE INDEX ix_reserva_mes_checkin ON reserva (TRUNC(fecha_checkin, ''MM'')) ' ||
                     'TABLESPACE ts_turismo_idx';
   DBMS_STATS.GATHER_TABLE_STATS(USER, 'RESERVA', method_opt => 'FOR ALL HIDDEN COLUMNS SIZE AUTO',
                                 cascade => TRUE);
   DBMS_OUTPUT.PUT_LINE('*** CREATE INDEX ix_reserva_mes_checkin ON reserva (TRUNC(fecha_checkin, ''MM''))');

   SELECT i.clustering_factor, t.blocks, t.num_rows INTO v_cf, v_blq, v_filas
     FROM user_indexes i JOIN user_tables t ON t.table_name = i.table_name
    WHERE i.index_name = 'IX_RESERVA_MES_CHECKIN';
   DBMS_OUTPUT.PUT_LINE('Clustering factor = ' || v_cf || ' · bloques de la tabla = ' || v_blq ||
                        ' · filas = ' || v_filas);

   DBMS_OUTPUT.PUT_LINE('--- PLAN con el índice creado: el optimizador lo ignora ---');
   pkg_medicion.plan(c_q);
   pkg_medicion.medir('Q5 llegadas del mes · con índice', c_q);

   DBMS_OUTPUT.PUT_LINE('--- PLAN FORZADO con /*+ INDEX */ ---');
   pkg_medicion.plan(c_q_forzada);
   pkg_medicion.medir('Q5 llegadas del mes · índice FORZADO', c_q_forzada);
END;
/


PROMPT
PROMPT ############ RESUMEN DE MEDICIONES ############
EXEC pkg_medicion.resumen

-- Decisión: IX_RESERVA_ESTADO e IX_RESERVA_MES_CHECKIN no se conservan.
-- El optimizador no los usa para los reportes que motivaron su creación
-- (forzado, el de estado empeora y el del mes casi no ahorra bloques), y
-- cada INSERT/UPDATE de RESERVA tendría que mantenerlos: un índice que no
-- se lee es costo puro de escritura y de disco.
DROP INDEX ix_reserva_estado;
DROP INDEX ix_reserva_mes_checkin;

PROMPT
PROMPT === Índices de la Entrega 3 que quedan en el esquema ===
SELECT i.index_name, i.table_name, i.index_type, i.tablespace_name,
       i.clustering_factor, ROUND(s.bytes / 1024) AS kb
  FROM user_indexes i JOIN user_segments s ON s.segment_name = i.index_name
 WHERE i.index_name IN ('IX_RESERVA_ALOJ_CHECKIN', 'IX_CLIENTE_EMAIL_UPPER', 'IX_RESERVA_CLIENTE')
 ORDER BY i.index_name;

SELECT index_name, column_position, column_name
  FROM user_ind_columns
 WHERE index_name IN ('IX_RESERVA_ALOJ_CHECKIN', 'IX_CLIENTE_EMAIL_UPPER', 'IX_RESERVA_CLIENTE')
 ORDER BY index_name, column_position;

PROMPT === Expresión del índice basado en función ===
SELECT index_name, column_expression
  FROM user_ind_expressions
 WHERE index_name = 'IX_CLIENTE_EMAIL_UPPER';

PROMPT
PROMPT ############ FIN DE ÍNDICES ############
