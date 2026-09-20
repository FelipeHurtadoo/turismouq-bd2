-- =====================================================================
-- TurismoUQ · 07_vistas_y_mv.sql
-- Ejecutar como: TURISMO_UQ
--
-- 1) V_NOCHE_VENDIDA  : vista base de todo el análisis (grano = noche)
-- 2) V_INVENTARIO_NOCHE: noches-habitación disponibles (denominador de ocupación)
-- 3) MV_OCUPACION_MENSUAL : vista materializada exigida por la Entrega 1
-- =====================================================================

SET ECHO ON

-- ---------------------------------------------------------------------
-- 1) VISTA BASE: una fila por (línea de reserva, noche)
-- ---------------------------------------------------------------------
-- Esta vista es la pieza central del modelo analítico. "Explota" cada
-- estadía en sus noches y le asigna a CADA noche la tarifa de la temporada
-- a la que pertenece. Así:
--   · el ingreso queda atribuido a la temporada correcta aunque la estadía
--     cruce el 15 de diciembre;
--   · contar filas = contar noches-habitación vendidas (ocupación);
--   · las 8 consultas se apoyan en un mismo grano, lo que hace que sus
--     resultados sean mutuamente consistentes.
--
-- Se excluyen CANCELADA, PENDIENTE y NO_SHOW: no son ingreso devengado.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_noche_vendida AS
SELECT r.id_reserva,
       rh.id_reserva_habitacion,
       rh.id_habitacion,
       h.id_alojamiento,
       h.categoria,
       a.id_municipio,
       a.id_tipo,
       r.id_cliente,
       r.canal,
       r.estado,
       d.fecha,
       d.anio,
       d.mes,
       d.anio_mes,
       d.id_temporada,
       t.valor_noche
  FROM reserva            r
  JOIN reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
  JOIN habitacion         h  ON h.id_habitacion  = rh.id_habitacion
  JOIN alojamiento        a  ON a.id_alojamiento = h.id_alojamiento
  JOIN dim_tiempo         d  ON d.fecha >= r.fecha_checkin
                            AND d.fecha <  r.fecha_checkout
  JOIN tarifa             t  ON t.id_alojamiento = h.id_alojamiento
                            AND t.categoria      = h.categoria
                            AND t.id_temporada   = d.id_temporada
 WHERE r.estado IN ('CONFIRMADA','COMPLETADA');

COMMENT ON TABLE v_noche_vendida IS
   'Grano: una noche-habitación vendida, con su tarifa de temporada';

-- ---------------------------------------------------------------------
-- 2) INVENTARIO: noches-habitación DISPONIBLES por municipio y mes
-- ---------------------------------------------------------------------
-- Denominador de la ocupación: habitaciones activas x días del mes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_inventario_noche AS
SELECT a.id_municipio,
       a.id_alojamiento,
       d.anio,
       d.mes,
       d.anio_mes,
       COUNT(*) AS noches_disponibles
  FROM habitacion  h
  JOIN alojamiento a ON a.id_alojamiento = h.id_alojamiento
  CROSS JOIN dim_tiempo d
 WHERE h.activa = 'S'
   AND a.activo = 'S'
 GROUP BY a.id_municipio, a.id_alojamiento, d.anio, d.mes, d.anio_mes;

-- ---------------------------------------------------------------------
-- 3) CONSULTA 6 · VISTA MATERIALIZADA DE OCUPACIÓN MENSUAL
-- ---------------------------------------------------------------------
-- Pregunta de negocio: ¿cuál es la ocupación, el ingreso y la tarifa media
-- de cada municipio en cada mes? Es el tablero que la gerencia mira todos
-- los días y que hoy tarda segundos porque hay que explotar 25.000 estadías
-- en ~80.000 noches.
--
-- POLÍTICA DE REFRESCO — comparación de alternativas:
--
--   ON COMMIT + FAST : descartada. Obligaría a Oracle a mantener la MV
--     dentro de cada transacción de reserva. La plataforma es OLTP en el
--     mostrador (recepción crea reservas todo el día); penalizar cada INSERT
--     para acelerar un informe que se consulta unas pocas veces al día es un
--     mal negocio. Además serializa los COMMIT sobre la misma fila agregada.
--
--   FAST ON DEMAND : técnicamente NO es viable aquí, y hay que saber por qué:
--     el refresco rápido de una MV con agregados exige MATERIALIZED VIEW LOG
--     en todas las tablas base (con ROWID, SEQUENCE e INCLUDING NEW VALUES),
--     y además Oracle no admite refresco rápido cuando la definición incluye
--     una condición de UNIÓN POR RANGO como
--          d.fecha >= r.fecha_checkin AND d.fecha < r.fecha_checkout
--     (no es un equi-join). Verificable con DBMS_MVIEW.EXPLAIN_MVIEW.
--
--   COMPLETE ON DEMAND (ELEGIDA) : el recálculo completo sobre este volumen
--     toma unos pocos segundos y se programa a las 2:00 a.m., cuando no hay
--     operación. La ocupación del mes es un indicador de gestión, no un dato
--     de tiempo real: un desfase de horas es irrelevante para la decisión que
--     soporta. Se deja además ON DEMAND explícito para poder forzar el
--     refresco en la sustentación con DBMS_MVIEW.REFRESH.
--
-- BUILD IMMEDIATE: se puebla al crearla, para poder consultarla enseguida.
-- ENABLE QUERY REWRITE: permite que el optimizador redirija automáticamente
--     hacia la MV consultas equivalentes escritas contra las tablas base.
-- ---------------------------------------------------------------------
-- DROP idempotente: no falla si la MV aún no existe (base limpia)
BEGIN
   EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW mv_ocupacion_mensual';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

CREATE MATERIALIZED VIEW mv_ocupacion_mensual
   TABLESPACE ts_turismo_dat
   BUILD IMMEDIATE
   REFRESH COMPLETE
   ON DEMAND
   START WITH SYSDATE
   -- Refresco diario a las 02:00. OJO: la expresión del NEXT se almacena como
   -- texto y Oracle la reevalúa en cada refresco, así que NO se le puede poner
   -- un comentario en la misma línea (produce ORA-23319).
   NEXT TRUNC(SYSDATE + 1) + 2/24
   ENABLE QUERY REWRITE
AS
SELECT nv.id_municipio,
       nv.anio,
       nv.mes,
       nv.anio_mes,
       COUNT(*)                  AS noches_vendidas,
       COUNT(DISTINCT nv.id_reserva) AS reservas,
       SUM(nv.valor_noche)       AS ingreso_alojamiento,
       ROUND(AVG(nv.valor_noche), 2) AS tarifa_media_noche
  FROM v_noche_vendida nv
 GROUP BY nv.id_municipio, nv.anio, nv.mes, nv.anio_mes;

CREATE INDEX ix_mv_ocup_mun_mes
   ON mv_ocupacion_mensual (id_municipio, anio, mes)
   TABLESPACE ts_turismo_idx;

-- Refresco manual (el que se ejecuta en vivo durante la sustentación):
-- BEGIN DBMS_MVIEW.REFRESH('MV_OCUPACION_MENSUAL', 'C'); END;
-- /

-- Diagnóstico de por qué NO es posible el refresco FAST (para defenderlo):
-- BEGIN DBMS_MVIEW.EXPLAIN_MVIEW('MV_OCUPACION_MENSUAL'); END;
-- /
-- SELECT capability_name, possible, msgtxt FROM mv_capabilities_table
--  WHERE capability_name LIKE 'REFRESH_FAST%' AND possible = 'N';
-- (requiere ejecutar antes ?/rdbms/admin/utlxmv.sql para crear la tabla)

PROMPT === Vista materializada creada ===
SELECT mview_name, refresh_mode, refresh_method, last_refresh_type, staleness
  FROM user_mviews;

PROMPT === Muestra: ocupación de la MV ===
SELECT m.nombre AS municipio, v.anio_mes, v.noches_vendidas,
       v.ingreso_alojamiento
  FROM mv_ocupacion_mensual v
  JOIN municipio m ON m.id_municipio = v.id_municipio
 WHERE v.anio = 2025 AND v.mes = 12
 ORDER BY v.ingreso_alojamiento DESC
 FETCH FIRST 12 ROWS ONLY;
