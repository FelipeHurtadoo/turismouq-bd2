-- =====================================================================
-- TurismoUQ · 08_consultas_analisis.sql
-- Ejecutar como: TURISMO_UQ
--
-- Las OCHO consultas de análisis exigidas por la Entrega 1:
--   1. PIVOT            · ocupación por municipio y mes
--   2. ROLLUP + GROUPING· ingresos por municipio, tipo y temporada
--   3. RANK + PARTITION · top 3 alojamientos por municipio
--   4. LAG              · variación de ingresos mes contra mes
--   5. Variables de enlace · ingresos en un rango de fechas
--   6. Vista materializada · está en 07_vistas_y_mv.sql (aquí se consulta)
--   7. UNPIVOT          · calificaciones de reseñas por dimensión
--   8. Consulta libre   · ADR / RevPAR e índice de estacionalidad
-- =====================================================================

SET LINESIZE 250
SET PAGESIZE 100
SET DEFINE OFF

-- =====================================================================
-- CONSULTA 1 · OCUPACIÓN POR MUNICIPIO Y MES (PIVOT)
-- =====================================================================
-- Definición de ocupación (decisión de diseño, no viene del documento):
--     ocupación % = noches-habitación vendidas / noches-habitación disponibles
--     donde disponibles = habitaciones activas del municipio x días del mes.
-- Es el indicador estándar de la industria hotelera y el único que permite
-- comparar a Salento (mucha oferta) con Pijao (poca oferta).
--
-- Se analiza el año 2025 por ser el único año COMPLETO del histórico.
--
-- ¿Por qué PIVOT? La consulta agrupada natural devuelve 12 municipios x 12
-- meses = 144 filas verticales, ilegibles para comparar estacionalidad. PIVOT
-- gira los 12 meses a columnas y produce la matriz municipio x mes que se
-- lee de un vistazo. Es una transformación de PRESENTACIÓN, no de cálculo:
-- la agregación ya la hizo el MAX() dentro del PIVOT sobre un valor único
-- por celda.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 1 · Ocupación % por municipio y mes (2025) =====

WITH vendidas AS (
   SELECT nv.id_municipio, nv.mes, COUNT(*) AS noches
     FROM v_noche_vendida nv
    WHERE nv.anio = 2025
    GROUP BY nv.id_municipio, nv.mes
),
disponibles AS (
   SELECT iv.id_municipio, iv.mes, SUM(iv.noches_disponibles) AS noches
     FROM v_inventario_noche iv
    WHERE iv.anio = 2025
    GROUP BY iv.id_municipio, iv.mes
),
ocupacion AS (
   SELECT m.nombre AS municipio,
          dsp.mes,
          ROUND(100 * NVL(vnd.noches, 0) / dsp.noches, 1) AS pct
     FROM disponibles dsp
     JOIN municipio   m   ON m.id_municipio = dsp.id_municipio
     LEFT JOIN vendidas vnd ON vnd.id_municipio = dsp.id_municipio
                           AND vnd.mes          = dsp.mes
)
SELECT *
  FROM ocupacion
 PIVOT (MAX(pct) FOR mes IN (1 AS ENE, 2 AS FEB, 3 AS MAR, 4 AS ABR,
                             5 AS MAY, 6 AS JUN, 7 AS JUL, 8 AS AGO,
                             9 AS SEP,10 AS OCT,11 AS NOV,12 AS DIC))
 ORDER BY municipio;

-- Resultado esperado: 12 filas (una por municipio) y 12 columnas de meses.
-- Los picos deben verse en JUN-JUL y DIC; los valles en FEB, MAY y SEP.


-- =====================================================================
-- CONSULTA 2 · INGRESOS POR MUNICIPIO, TIPO Y TEMPORADA (ROLLUP + GROUPING)
-- =====================================================================
-- Definición de ingreso (decisión de diseño): ingreso DEVENGADO por
-- alojamiento, es decir la suma de las tarifas noche a noche de reservas
-- confirmadas o completadas. NO se usan los pagos, porque un pago puede ir
-- por anticipos y cruzarse de mes, y porque un pago no sabe a qué temporada
-- pertenece la noche que financia.
--
-- Se usa ROLLUP y no CUBE: ROLLUP genera la jerarquía
--     municipio > tipo de alojamiento > temporada
-- que es exactamente como se lee un estado de resultados. CUBE generaría
-- además combinaciones sin sentido jerárquico (p. ej. total por temporada
-- ignorando el municipio pero desagregado por tipo), multiplicando las filas
-- sin aportar a la pregunta.
--
-- GROUPING(col) devuelve 1 cuando la fila es un SUBTOTAL respecto de esa
-- columna. Es imprescindible para no confundir un subtotal con un NULL real
-- de los datos.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 2 · Ingresos con ROLLUP y GROUPING (2025) =====

SELECT CASE WHEN GROUPING(m.nombre) = 1 THEN '>> TOTAL GENERAL'
            ELSE m.nombre END                          AS municipio,
       CASE WHEN GROUPING(ta.nombre) = 1
                 AND GROUPING(m.nombre) = 0 THEN '> Subtotal municipio'
            WHEN GROUPING(ta.nombre) = 1   THEN ' '
            ELSE ta.nombre END                         AS tipo_alojamiento,
       CASE WHEN GROUPING(t.tipo) = 1
                 AND GROUPING(ta.nombre) = 0 THEN '> Subtotal tipo'
            WHEN GROUPING(t.tipo) = 1       THEN ' '
            ELSE t.tipo END                            AS temporada,
       COUNT(*)                                        AS noches,
       SUM(nv.valor_noche)                             AS ingreso,
       -- GROUPING_ID codifica en binario qué columnas están agregadas:
       -- 0 = detalle · 1 = subtotal por tipo · 3 = subtotal por municipio
       -- 7 = total general
       GROUPING_ID(m.nombre, ta.nombre, t.tipo)        AS nivel
  FROM v_noche_vendida  nv
  JOIN municipio        m  ON m.id_municipio = nv.id_municipio
  JOIN tipo_alojamiento ta ON ta.id_tipo     = nv.id_tipo
  JOIN temporada        t  ON t.id_temporada = nv.id_temporada
 WHERE nv.anio = 2025
 GROUP BY ROLLUP (m.nombre, ta.nombre, t.tipo)
 ORDER BY GROUPING_ID(m.nombre, ta.nombre, t.tipo),
          m.nombre, ta.nombre, t.tipo;


-- =====================================================================
-- CONSULTA 3 · TOP 3 ALOJAMIENTOS POR INGRESO DENTRO DE CADA MUNICIPIO
--              (RANK con PARTITION BY)
-- =====================================================================
-- Un FETCH FIRST 3 ROWS ONLY devolvería los 3 mejores del DEPARTAMENTO,
-- que es otra pregunta. PARTITION BY id_municipio reinicia la numeración en
-- cada municipio y devuelve 3 filas POR MUNICIPIO.
--
-- Se usa RANK y no ROW_NUMBER a propósito: si dos alojamientos empatan en
-- ingreso, ambos merecen el mismo puesto; ROW_NUMBER rompería el empate de
-- forma arbitraria. Consecuencia aceptada: un municipio puede devolver más
-- de 3 filas si hay empate en el tercer puesto.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 3 · Top 3 alojamientos por municipio (RANK) =====

WITH ingresos AS (
   SELECT nv.id_municipio,
          nv.id_alojamiento,
          SUM(nv.valor_noche) AS ingreso,
          COUNT(*)            AS noches
     FROM v_noche_vendida nv
    WHERE nv.anio = 2025
    GROUP BY nv.id_municipio, nv.id_alojamiento
),
ranking AS (
   SELECT i.*,
          RANK() OVER (PARTITION BY i.id_municipio
                       ORDER BY i.ingreso DESC) AS puesto,
          ROUND(100 * RATIO_TO_REPORT(i.ingreso)
                      OVER (PARTITION BY i.id_municipio), 1) AS pct_municipio
     FROM ingresos i
)
SELECT m.nombre AS municipio,
       r.puesto,
       a.nombre AS alojamiento,
       ta.nombre AS tipo,
       r.noches,
       r.ingreso,
       r.pct_municipio AS pct_del_municipio
  FROM ranking          r
  JOIN municipio        m  ON m.id_municipio   = r.id_municipio
  JOIN alojamiento      a  ON a.id_alojamiento = r.id_alojamiento
  JOIN tipo_alojamiento ta ON ta.id_tipo       = a.id_tipo
 WHERE r.puesto <= 3
 ORDER BY m.nombre, r.puesto;


-- =====================================================================
-- CONSULTA 4 · VARIACIÓN DE INGRESOS MES CONTRA MES (LAG)
-- =====================================================================
-- LAG(x, 1) OVER (ORDER BY mes) trae el valor de la fila anterior sin
-- necesidad de auto-unir la tabla consigo misma desplazada un mes.
--
-- Manejo del primer mes: LAG devuelve NULL porque no existe mes anterior.
-- Se deja NULL en la diferencia (no se pone 0, que mentiría diciendo "no
-- varió") y el porcentaje se protege con NULLIF para evitar división por
-- cero si un mes cerrara en 0.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 4 · Variación mes contra mes (LAG) =====

WITH mensual AS (
   SELECT nv.anio_mes,
          SUM(nv.valor_noche) AS ingreso
     FROM v_noche_vendida nv
    GROUP BY nv.anio_mes
)
SELECT anio_mes,
       ingreso,
       LAG(ingreso, 1) OVER (ORDER BY anio_mes)                AS ingreso_mes_anterior,
       ingreso - LAG(ingreso, 1) OVER (ORDER BY anio_mes)      AS diferencia,
       ROUND(100 * (ingreso - LAG(ingreso, 1) OVER (ORDER BY anio_mes))
             / NULLIF(LAG(ingreso, 1) OVER (ORDER BY anio_mes), 0), 1)
                                                               AS variacion_pct,
       -- comparación interanual: mismo mes del año anterior (12 posiciones atrás)
       LAG(ingreso, 12) OVER (ORDER BY anio_mes)               AS ingreso_anio_anterior
  FROM mensual
 ORDER BY anio_mes;


-- =====================================================================
-- CONSULTA 5 · CONSULTA PARAMETRIZADA CON VARIABLES DE ENLACE
-- =====================================================================
-- Por qué variables de enlace y no concatenar literales:
--   · el plan de ejecución se reutiliza desde la caché (una sola versión del
--     cursor en lugar de una por cada par de fechas);
--   · elimina la inyección de SQL;
--   · reduce el "hard parse", que en OLTP es el principal consumidor de CPU.
--
-- Detalle de sintaxis: en SQL*Plus / SQL Developer el comando VARIABLE NO
-- admite el tipo DATE. Se declaran como VARCHAR2 y se convierten con
-- TO_DATE dentro de la consulta, con máscara explícita para no depender del
-- NLS_DATE_FORMAT del cliente.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 5 · Ingresos en un rango de fechas (bind variables) =====

VARIABLE p_fecha_ini VARCHAR2(10)
VARIABLE p_fecha_fin VARCHAR2(10)

BEGIN
   :p_fecha_ini := '2025-06-01';
   :p_fecha_fin := '2025-07-31';
END;
/

SELECT m.nombre                     AS municipio,
       ta.nombre                    AS tipo_alojamiento,
       COUNT(DISTINCT nv.id_reserva) AS reservas,
       COUNT(*)                     AS noches_vendidas,
       SUM(nv.valor_noche)          AS ingreso,
       ROUND(AVG(nv.valor_noche))   AS tarifa_media
  FROM v_noche_vendida  nv
  JOIN municipio        m  ON m.id_municipio = nv.id_municipio
  JOIN tipo_alojamiento ta ON ta.id_tipo     = nv.id_tipo
 WHERE nv.fecha BETWEEN TO_DATE(:p_fecha_ini, 'YYYY-MM-DD')
                    AND TO_DATE(:p_fecha_fin, 'YYYY-MM-DD')
 GROUP BY m.nombre, ta.nombre
 ORDER BY ingreso DESC;

-- Para repetir con otro rango basta con reasignar las variables:
--   BEGIN :p_fecha_ini := '2024-12-15'; :p_fecha_fin := '2025-01-15'; END;
--   /
-- y volver a ejecutar la consulta: Oracle reutiliza el mismo plan.


-- =====================================================================
-- CONSULTA 6 · VISTA MATERIALIZADA DE OCUPACIÓN MENSUAL
-- =====================================================================
-- La MV se crea en 07_vistas_y_mv.sql (con su política de refresco
-- justificada). Aquí se demuestra su uso y su ventaja.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 6 · Consulta sobre la vista materializada =====

SELECT m.nombre AS municipio,
       v.anio_mes,
       v.reservas,
       v.noches_vendidas,
       v.ingreso_alojamiento,
       v.tarifa_media_noche,
       RANK() OVER (PARTITION BY v.anio_mes
                    ORDER BY v.ingreso_alojamiento DESC) AS puesto_del_mes
  FROM mv_ocupacion_mensual v
  JOIN municipio m ON m.id_municipio = v.id_municipio
 WHERE v.anio = 2025
   AND v.mes IN (7, 12)
 ORDER BY v.anio_mes, puesto_del_mes;

-- Demostración del ahorro: comparar tiempos y lecturas de bloques entre
-- esta consulta y la equivalente contra las tablas base.
-- SET AUTOTRACE TRACEONLY
-- ... misma consulta contra v_noche_vendida ...


-- =====================================================================
-- CONSULTA 7 · UNPIVOT · PERFIL DE CALIFICACIONES POR MUNICIPIO
-- =====================================================================
-- RESENA guarda cinco calificaciones en cinco COLUMNAS (limpieza, ubicación,
-- servicio, precio, general). Ese formato ancho es cómodo para capturar y
-- para el CHECK de cada columna, pero un tablero de calidad necesita el
-- formato largo: una fila por (municipio, dimensión, promedio), que es lo
-- único que se puede graficar, ordenar y comparar entre dimensiones.
--
-- UNPIVOT hace justo eso: convierte N columnas en N filas, generando una
-- columna con el NOMBRE de la métrica y otra con su VALOR. Es la operación
-- inversa del PIVOT de la consulta 1.
--
-- Por defecto UNPIVOT EXCLUDE NULLS (descarta las celdas nulas). Aquí no hay
-- nulos porque las cinco calificaciones son NOT NULL, pero se deja indicado
-- que INCLUDE NULLS existe si se quisiera conservar el hueco.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 7 · Perfil de calificaciones (UNPIVOT) =====

SELECT municipio, dimension, promedio, resenas
  FROM (
     SELECT m.nombre                          AS municipio,
            COUNT(*)                          AS resenas,
            ROUND(AVG(re.calif_limpieza),  2) AS limpieza,
            ROUND(AVG(re.calif_ubicacion), 2) AS ubicacion,
            ROUND(AVG(re.calif_servicio),  2) AS servicio,
            ROUND(AVG(re.calif_precio),    2) AS precio,
            ROUND(AVG(re.calif_general),   2) AS general
       FROM resena      re
       JOIN reserva     r ON r.id_reserva     = re.id_reserva
       JOIN alojamiento a ON a.id_alojamiento = r.id_alojamiento
       JOIN municipio   m ON m.id_municipio   = a.id_municipio
      GROUP BY m.nombre
  )
  UNPIVOT (promedio FOR dimension IN (limpieza  AS 'Limpieza',
                                      ubicacion AS 'Ubicacion',
                                      servicio  AS 'Servicio',
                                      precio    AS 'Relacion precio-valor',
                                      general   AS 'Calificacion general'))
 ORDER BY municipio, promedio DESC;

-- Resultado esperado: 12 municipios x 5 dimensiones = 60 filas.
-- Lectura de negocio: identificar en qué dimensión concreta está fallando
-- cada municipio, algo que el promedio general esconde.


-- =====================================================================
-- CONSULTA 8 · LIBRE · ADR, RevPAR E ÍNDICE DE ESTACIONALIDAD
-- =====================================================================
-- Pregunta de negocio: "¿qué municipios ganan dinero por tener buenos
-- precios y cuáles por llenar habitaciones, y cuáles dependen peligrosamente
-- de la temporada alta?"
--
-- Se eligió esta y no "cuál alojamiento factura más" porque facturar mucho
-- no significa rendir bien: un hotel de 40 habitaciones factura más que un
-- glamping de 6 aun estando medio vacío. Los indicadores estándar del sector
-- separan las dos causas:
--
--   ADR    (Average Daily Rate)     = ingreso / noches VENDIDAS
--                                     -> cuánto cobro cuando vendo
--   RevPAR (Revenue Per Available Room) = ingreso / noches DISPONIBLES
--                                     -> cuánto rinde cada habitación exista
--                                        o no huésped. RevPAR = ADR x ocupación
--
--   Índice de estacionalidad = ingreso en temporada ALTA / ingreso total.
--   Un valor alto señala un destino frágil: vive de tres semanas del año.
--
-- Técnicas: agregación en subconsultas + funciones de ventana sin PARTITION
-- (AVG(...) OVER ()) para comparar cada municipio contra el promedio
-- departamental en la misma pasada, sin una segunda consulta.
-- =====================================================================
PROMPT
PROMPT ===== CONSULTA 8 · ADR, RevPAR e índice de estacionalidad (2025) =====

WITH ingreso_mun AS (
   SELECT nv.id_municipio,
          COUNT(*)             AS noches_vendidas,
          SUM(nv.valor_noche)  AS ingreso,
          SUM(CASE WHEN t.tipo = 'ALTA' THEN nv.valor_noche ELSE 0 END) AS ingreso_alta
     FROM v_noche_vendida nv
     JOIN temporada t ON t.id_temporada = nv.id_temporada
    WHERE nv.anio = 2025
    GROUP BY nv.id_municipio
),
inventario_mun AS (
   SELECT id_municipio, SUM(noches_disponibles) AS noches_disponibles
     FROM v_inventario_noche
    WHERE anio = 2025
    GROUP BY id_municipio
)
SELECT m.nombre                                              AS municipio,
       i.noches_vendidas,
       v.noches_disponibles,
       ROUND(100 * i.noches_vendidas / v.noches_disponibles, 1) AS ocupacion_pct,
       ROUND(i.ingreso / i.noches_vendidas)                  AS adr,
       ROUND(i.ingreso / v.noches_disponibles)               AS revpar,
       ROUND(AVG(i.ingreso / v.noches_disponibles) OVER ())  AS revpar_departamental,
       CASE WHEN i.ingreso / v.noches_disponibles
                 > AVG(i.ingreso / v.noches_disponibles) OVER ()
            THEN 'Por encima' ELSE 'Por debajo' END          AS vs_departamento,
       ROUND(100 * i.ingreso_alta / i.ingreso, 1)            AS pct_ingreso_temporada_alta,
       RANK() OVER (ORDER BY i.ingreso / v.noches_disponibles DESC) AS puesto_revpar
  FROM ingreso_mun    i
  JOIN inventario_mun v ON v.id_municipio = i.id_municipio
  JOIN municipio      m ON m.id_municipio = i.id_municipio
 ORDER BY puesto_revpar;

PROMPT
PROMPT ===== Fin de las 8 consultas de análisis =====
