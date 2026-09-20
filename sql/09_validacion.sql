-- =====================================================================
-- TurismoUQ · 09_validacion.sql
-- Ejecutar como: TURISMO_UQ
--
-- Checklist automatizado. Cada bloque devuelve OK o FALLA. Si algo dice
-- FALLA, la entrega no está lista.
-- =====================================================================

SET LINESIZE 200
SET PAGESIZE 200
SET FEEDBACK OFF

PROMPT
PROMPT ############ 1. VOLÚMENES MÍNIMOS EXIGIDOS ############

SELECT tabla, exigido, real,
       CASE WHEN real >= exigido THEN 'OK' ELSE 'FALLA' END AS estado
  FROM (
   SELECT 'MUNICIPIO'          AS tabla,    12 AS exigido, (SELECT COUNT(*) FROM municipio)          AS real FROM dual UNION ALL
   SELECT 'ALOJAMIENTO',                    60,            (SELECT COUNT(*) FROM alojamiento)             FROM dual UNION ALL
   SELECT 'HABITACION',                    400,            (SELECT COUNT(*) FROM habitacion)              FROM dual UNION ALL
   SELECT 'CLIENTE',                      3000,            (SELECT COUNT(*) FROM cliente)                 FROM dual UNION ALL
   SELECT 'RESERVA',                     25000,            (SELECT COUNT(*) FROM reserva)                 FROM dual UNION ALL
   SELECT 'RESERVA_SERVICIO',            40000,            (SELECT COUNT(*) FROM reserva_servicio)        FROM dual UNION ALL
   SELECT 'RESERVA_HABITACION',          25000,            (SELECT COUNT(*) FROM reserva_habitacion)      FROM dual UNION ALL
   SELECT 'TARIFA',                       1000,            (SELECT COUNT(*) FROM tarifa)                  FROM dual UNION ALL
   SELECT 'PAGO',                         1000,            (SELECT COUNT(*) FROM pago)                    FROM dual UNION ALL
   SELECT 'RESENA',                        500,            (SELECT COUNT(*) FROM resena)                  FROM dual UNION ALL
   SELECT 'DIM_TIEMPO',                   1096,            (SELECT COUNT(*) FROM dim_tiempo)              FROM dual
 )
 ORDER BY tabla;

PROMPT
PROMPT ############ 2. RESERVAS REPARTIDAS EN 2024-2026 ############

SELECT EXTRACT(YEAR FROM fecha_checkin) AS anio,
       COUNT(*) AS reservas,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
  FROM reserva
 GROUP BY EXTRACT(YEAR FROM fecha_checkin)
 ORDER BY anio;

PROMPT
PROMPT ############ 2b. COBERTURA: los 12 municipios con oferta ############
PROMPT ## Ninguno puede quedar en 0, o desaparecería de las consultas de analisis.

SELECT m.nombre AS municipio,
       COUNT(a.id_alojamiento) AS alojamientos,
       CASE WHEN COUNT(a.id_alojamiento) > 0 THEN 'OK' ELSE 'FALLA' END AS estado
  FROM municipio m
  LEFT JOIN alojamiento a ON a.id_municipio = m.id_municipio
 GROUP BY m.nombre
 ORDER BY alojamientos DESC, m.nombre;

PROMPT
PROMPT ############ 3. INTEGRIDAD REFERENCIAL (todo debe dar 0) ############

SELECT 'Habitaciones sin alojamiento'      AS prueba, COUNT(*) AS huerfanos FROM habitacion h
  WHERE NOT EXISTS (SELECT 1 FROM alojamiento a WHERE a.id_alojamiento = h.id_alojamiento)
UNION ALL
SELECT 'Alojamientos sin municipio',        COUNT(*) FROM alojamiento a
  WHERE NOT EXISTS (SELECT 1 FROM municipio m WHERE m.id_municipio = a.id_municipio)
UNION ALL
SELECT 'Reservas sin cliente',              COUNT(*) FROM reserva r
  WHERE NOT EXISTS (SELECT 1 FROM cliente c WHERE c.id_cliente = r.id_cliente)
UNION ALL
SELECT 'Reservas SIN habitaciones',         COUNT(*) FROM reserva r
  WHERE NOT EXISTS (SELECT 1 FROM reserva_habitacion rh WHERE rh.id_reserva = r.id_reserva)
UNION ALL
SELECT 'Habitacion de otro alojamiento',    COUNT(*)
  FROM reserva_habitacion rh
  JOIN reserva    r ON r.id_reserva    = rh.id_reserva
  JOIN habitacion h ON h.id_habitacion = rh.id_habitacion
 WHERE h.id_alojamiento <> r.id_alojamiento
UNION ALL
SELECT 'Pagos sin reserva',                 COUNT(*) FROM pago p
  WHERE NOT EXISTS (SELECT 1 FROM reserva r WHERE r.id_reserva = p.id_reserva)
UNION ALL
SELECT 'Tarifas sin temporada',             COUNT(*) FROM tarifa t
  WHERE NOT EXISTS (SELECT 1 FROM temporada te WHERE te.id_temporada = t.id_temporada);

PROMPT
PROMPT ############ 4. REGLAS DE FECHAS Y TEMPORADAS (todo debe dar 0) ############

SELECT 'Checkout <= checkin'                AS prueba, COUNT(*) AS filas
  FROM reserva WHERE fecha_checkout <= fecha_checkin
UNION ALL
SELECT 'Reserva posterior al checkin',      COUNT(*)
  FROM reserva WHERE fecha_reserva > fecha_checkin
UNION ALL
SELECT 'Estadias fuera de 2024-2026',       COUNT(*)
  FROM reserva WHERE fecha_checkin < DATE '2024-01-01'
                  OR fecha_checkout > DATE '2027-01-01'
UNION ALL
SELECT 'Dias sin temporada asignada',       COUNT(*)
  FROM dim_tiempo WHERE id_temporada IS NULL
UNION ALL
SELECT 'Temporadas con rango invalido',     COUNT(*)
  FROM temporada WHERE fecha_fin < fecha_inicio
UNION ALL
-- Prueba de NO SUPERPOSICIÓN entre temporadas: una auto-unión que busque
-- cualquier par de temporadas distintas cuyos rangos se crucen.
SELECT 'Temporadas superpuestas',           COUNT(*)
  FROM temporada a JOIN temporada b
    ON a.id_temporada < b.id_temporada
   AND a.fecha_inicio <= b.fecha_fin
   AND b.fecha_inicio <= a.fecha_fin
UNION ALL
SELECT 'Servicios fuera de la estadia',     COUNT(*)
  FROM reserva_servicio rs JOIN reserva r ON r.id_reserva = rs.id_reserva
 WHERE rs.fecha_servicio < r.fecha_checkin
    OR rs.fecha_servicio >= r.fecha_checkout;

PROMPT
PROMPT ############ 5. SOLAPAMIENTO DE HABITACIONES (debe dar 0) ############
PROMPT ## Dos reservas activas NO pueden usar la misma habitacion la misma noche.
PROMPT ## Es la precondicion del disparador de fila de la Entrega 2.

SELECT COUNT(*) AS pares_solapados
  FROM reserva_habitacion rh1
  JOIN reserva r1 ON r1.id_reserva = rh1.id_reserva
  JOIN reserva_habitacion rh2 ON rh2.id_habitacion = rh1.id_habitacion
                             AND rh2.id_reserva   <> rh1.id_reserva
  JOIN reserva r2 ON r2.id_reserva = rh2.id_reserva
 WHERE r1.id_reserva < r2.id_reserva
   AND r1.fecha_checkin < r2.fecha_checkout
   AND r2.fecha_checkin < r1.fecha_checkout;

PROMPT
PROMPT ############ 6. COHERENCIA DE VALORES ############

SELECT 'Reservas con valor 0'               AS prueba, COUNT(*) AS filas
  FROM reserva WHERE valor_alojamiento = 0
UNION ALL
SELECT 'Cabecera <> suma de habitaciones',  COUNT(*)
  FROM (SELECT r.id_reserva
          FROM reserva r
          JOIN reserva_habitacion rh ON rh.id_reserva = r.id_reserva
         GROUP BY r.id_reserva, r.valor_alojamiento
        HAVING ABS(r.valor_alojamiento - SUM(rh.valor_noches)) > 0.01)
UNION ALL
SELECT 'Capacidad excedida',                COUNT(*)
  FROM (SELECT r.id_reserva
          FROM reserva r
          JOIN reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
          JOIN habitacion h          ON h.id_habitacion  = rh.id_habitacion
         GROUP BY r.id_reserva, r.num_huespedes
        HAVING r.num_huespedes > SUM(h.capacidad))
UNION ALL
SELECT 'Pagos mayores al total',            COUNT(*)
  FROM (SELECT p.id_reserva
          FROM pago p JOIN reserva r ON r.id_reserva = p.id_reserva
         WHERE p.estado = 'APROBADO'
         GROUP BY p.id_reserva, r.valor_total
        HAVING SUM(p.valor) > r.valor_total + 0.01);

PROMPT
PROMPT ############ 7. VERIFICACION DEL CALCULO MULTI-TEMPORADA ############
PROMPT ## Cuantas estadias atraviesan mas de una temporada y como se cobraron.

SELECT temporadas_atravesadas,
       COUNT(*)                       AS reservas,
       ROUND(AVG(valor), 0)           AS valor_promedio
  FROM (
     SELECT rh.id_reserva_habitacion,
            COUNT(DISTINCT d.id_temporada) AS temporadas_atravesadas,
            SUM(t.valor_noche)             AS valor
       FROM reserva_habitacion rh
       JOIN reserva    r ON r.id_reserva     = rh.id_reserva
       JOIN habitacion h ON h.id_habitacion  = rh.id_habitacion
       JOIN dim_tiempo d ON d.fecha >= r.fecha_checkin AND d.fecha < r.fecha_checkout
       JOIN tarifa     t ON t.id_alojamiento = h.id_alojamiento
                        AND t.categoria      = h.categoria
                        AND t.id_temporada   = d.id_temporada
      GROUP BY rh.id_reserva_habitacion
  )
 GROUP BY temporadas_atravesadas
 ORDER BY temporadas_atravesadas;

PROMPT ## Ejemplo concreto: una estadia que cruza temporadas, noche por noche.

SELECT * FROM (
   SELECT rh.id_reserva,
          d.fecha,
          te.nombre AS temporada,
          te.tipo,
          t.valor_noche
     FROM reserva_habitacion rh
     JOIN reserva    r  ON r.id_reserva     = rh.id_reserva
     JOIN habitacion h  ON h.id_habitacion  = rh.id_habitacion
     JOIN dim_tiempo d  ON d.fecha >= r.fecha_checkin AND d.fecha < r.fecha_checkout
     JOIN temporada  te ON te.id_temporada  = d.id_temporada
     JOIN tarifa     t  ON t.id_alojamiento = h.id_alojamiento
                       AND t.categoria      = h.categoria
                       AND t.id_temporada   = d.id_temporada
    WHERE rh.id_reserva_habitacion = (
             SELECT MIN(x.id_reserva_habitacion)
               FROM (SELECT rh2.id_reserva_habitacion
                       FROM reserva_habitacion rh2
                       JOIN reserva r2 ON r2.id_reserva = rh2.id_reserva
                       JOIN dim_tiempo d2 ON d2.fecha >= r2.fecha_checkin
                                         AND d2.fecha <  r2.fecha_checkout
                      GROUP BY rh2.id_reserva_habitacion
                     HAVING COUNT(DISTINCT d2.id_temporada) > 1) x)
    ORDER BY d.fecha)
 WHERE ROWNUM <= 10;

PROMPT
PROMPT ############ 8. OBJETOS DE BASE DE DATOS ############

SELECT object_type, COUNT(*) AS cantidad
  FROM user_objects
 GROUP BY object_type
 ORDER BY object_type;

SELECT 'Objetos invalidos' AS prueba, COUNT(*) AS cantidad
  FROM user_objects WHERE status <> 'VALID';

PROMPT
PROMPT ############ 9. UBICACION FISICA (TABLESPACES) ############

SELECT tablespace_name, COUNT(*) AS tablas
  FROM user_tables
 GROUP BY tablespace_name
 ORDER BY tablespace_name;

SELECT segment_name, segment_type, tablespace_name,
       ROUND(bytes/1024/1024, 2) AS mb
  FROM user_segments
 WHERE tablespace_name = 'TS_TURISMO_HIST'
 ORDER BY bytes DESC;

PROMPT
PROMPT ############ 10. RESTRICCIONES DECLARADAS ############

SELECT DECODE(constraint_type,'P','PRIMARY KEY','R','FOREIGN KEY',
                              'U','UNIQUE','C','CHECK / NOT NULL', constraint_type) AS tipo,
       COUNT(*) AS cantidad
  FROM user_constraints
 GROUP BY constraint_type
 ORDER BY 1;

PROMPT
PROMPT ############ 11. VISTA MATERIALIZADA ############

SELECT mview_name, refresh_method, refresh_mode, staleness, compile_state
  FROM user_mviews;

SELECT COUNT(*) AS filas_en_la_mv FROM mv_ocupacion_mensual;

SET FEEDBACK ON
PROMPT
PROMPT ############ FIN DE LA VALIDACION ############
