-- =====================================================================
-- TurismoUQ · 20_consultas_sustentacion.sql
-- Ejecutar como: TURISMO_UQ   (después de 07_vistas_y_mv.sql)
--
-- Las dos consultas que pidió la docente para la sustentación, distintas
-- de las ocho de la Entrega 1:
--   1. ¿Cuál fue la habitación con más reservas en temporada alta?
--   2. Listado de clientes con los municipios que visitan:
--      2a. clientes que han visitado MÁS municipios, con la lista de ellos
--      2b. en cada municipio, el cliente con más reservas
--
-- Las dos se apoyan en el mismo modelo de siempre: la temporada NO está en
-- la reserva sino en el calendario (DIM_TIEMPO -> TEMPORADA), así que "en
-- temporada alta" se resuelve noche por noche con V_NOCHE_VENDIDA.
-- Solo cuentan reservas CONFIRMADA o COMPLETADA (las demás no se hospedaron
-- o no se han pagado), el mismo criterio de las consultas de la Entrega 1.
-- =====================================================================

SET LINESIZE 220
SET PAGESIZE 100

-- =====================================================================
-- CONSULTA 1 · HABITACIÓN CON MÁS RESERVAS EN TEMPORADA ALTA
-- =====================================================================
-- Definición: una reserva cuenta para una habitación si al menos UNA de sus
-- noches en esa habitación cae en una temporada de tipo ALTA (Semana Santa,
-- mitad de año, puentes, diciembre-enero). Una estadía del 13 al 18 de
-- diciembre cuenta aunque solo las últimas noches sean de temporada alta:
-- por eso se cuenta COUNT(DISTINCT id_reserva) sobre las NOCHES de alta y
-- no sobre la fecha de llegada.
--
-- RANK y no ROW_NUMBER: si dos habitaciones empatan en el primer lugar, las
-- dos son "la habitación con más reservas"; ROW_NUMBER escogería una al azar.
-- Se muestran las 10 primeras posiciones para dar contexto al ganador.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 1 · Habitación con más reservas en temporada alta =====

WITH noches_alta AS (
   SELECT nv.id_habitacion,
          COUNT(DISTINCT nv.id_reserva) AS reservas_alta,
          COUNT(*)                      AS noches_alta,
          SUM(nv.valor_noche)           AS ingreso_alta
     FROM v_noche_vendida nv
     JOIN temporada t ON t.id_temporada = nv.id_temporada
    WHERE t.tipo = 'ALTA'
    GROUP BY nv.id_habitacion
),
ranking AS (
   SELECT RANK() OVER (ORDER BY na.reservas_alta DESC) AS puesto,
          h.id_habitacion,
          h.numero                                     AS habitacion,
          h.categoria,
          a.nombre                                     AS alojamiento,
          m.nombre                                     AS municipio,
          na.reservas_alta,
          na.noches_alta,
          na.ingreso_alta
     FROM noches_alta na
     JOIN habitacion  h ON h.id_habitacion  = na.id_habitacion
     JOIN alojamiento a ON a.id_alojamiento = h.id_alojamiento
     JOIN municipio   m ON m.id_municipio   = a.id_municipio
)
SELECT puesto, id_habitacion, habitacion, categoria, alojamiento, municipio,
       reservas_alta, noches_alta, ingreso_alta
  FROM ranking
 WHERE puesto <= 10
 ORDER BY puesto, ingreso_alta DESC;


-- =====================================================================
-- CONSULTA 2a · CLIENTES QUE HAN VISITADO MÁS MUNICIPIOS
-- =====================================================================
-- Pregunta de negocio: ¿quiénes son los viajeros que recorren el Quindío
-- (no los que vuelven siempre al mismo hotel)? Son el público de los planes
-- "ruta cafetera" que combinan varios municipios.
--
-- Paso 1 (visitas): una fila por (cliente, municipio) con cuántas reservas
-- tuvo ahí. Paso 2: por cliente, cuántos municipios distintos y la lista de
-- ellos con LISTAGG, ordenada de más a menos visitado.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 2a · Clientes que han visitado más municipios =====

WITH visitas AS (
   SELECT r.id_cliente,
          m.nombre  AS municipio,
          COUNT(*)  AS reservas
     FROM reserva     r
     JOIN alojamiento a ON a.id_alojamiento = r.id_alojamiento
     JOIN municipio   m ON m.id_municipio   = a.id_municipio
    WHERE r.estado IN ('CONFIRMADA', 'COMPLETADA')
    GROUP BY r.id_cliente, m.nombre
),
por_cliente AS (
   SELECT v.id_cliente,
          COUNT(*)        AS municipios_visitados,
          SUM(v.reservas) AS reservas,
          LISTAGG(v.municipio || ' (' || v.reservas || ')', ', ')
             WITHIN GROUP (ORDER BY v.reservas DESC, v.municipio) AS municipios
     FROM visitas v
    GROUP BY v.id_cliente
)
SELECT *
  FROM (SELECT RANK() OVER (ORDER BY pc.municipios_visitados DESC, pc.reservas DESC) AS puesto,
               c.id_cliente,
               c.nombres || ' ' || c.apellidos AS cliente,
               NVL(c.ciudad_origen, c.pais)    AS origen,
               pc.municipios_visitados,
               pc.reservas,
               pc.municipios
          FROM por_cliente pc
          JOIN cliente     c ON c.id_cliente = pc.id_cliente)
 WHERE puesto <= 15
 ORDER BY puesto, cliente;


-- =====================================================================
-- CONSULTA 2b · EN CADA MUNICIPIO, EL CLIENTE CON MÁS RESERVAS
-- =====================================================================
-- La otra lectura de la pregunta: el cliente más fiel de cada municipio.
-- RANK() OVER (PARTITION BY municipio ...) reinicia el conteo en cada
-- municipio, igual que la consulta 3 de la Entrega 1; con empate aparecen
-- todos los empatados.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 2b · Cliente con más reservas en cada municipio =====

WITH reservas_mun AS (
   SELECT m.nombre    AS municipio,
          r.id_cliente,
          COUNT(*)    AS reservas,
          SUM(r.valor_total) AS valor
     FROM reserva     r
     JOIN alojamiento a ON a.id_alojamiento = r.id_alojamiento
     JOIN municipio   m ON m.id_municipio   = a.id_municipio
    WHERE r.estado IN ('CONFIRMADA', 'COMPLETADA')
    GROUP BY m.nombre, r.id_cliente
)
SELECT municipio, cliente, reservas, valor
  FROM (SELECT rm.municipio,
               c.nombres || ' ' || c.apellidos AS cliente,
               rm.reservas,
               rm.valor,
               RANK() OVER (PARTITION BY rm.municipio ORDER BY rm.reservas DESC) AS puesto
          FROM reservas_mun rm
          JOIN cliente      c ON c.id_cliente = rm.id_cliente)
 WHERE puesto = 1
 ORDER BY municipio, valor DESC;
