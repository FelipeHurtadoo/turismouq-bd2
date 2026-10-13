"""
SQL de solo lectura para la interfaz. Son las mismas 8 consultas de
sql/08_consultas_analisis.sql (y las vistas de sql/07_vistas_y_mv.sql),
reescritas con bind variables nombradas para poder parametrizarlas desde
los formularios, en vez de los literales fijos del script original.

No se agrega PL/SQL nuevo para estas pantallas: son reportes de solo
lectura, así que una consulta SQL directa es la forma más simple y
correcta de servirlas.
"""

OCUPACION_PIVOT = """
WITH vendidas AS (
   SELECT nv.id_municipio, nv.mes, COUNT(*) AS noches
     FROM v_noche_vendida nv
    WHERE nv.anio = :anio
    GROUP BY nv.id_municipio, nv.mes
),
disponibles AS (
   SELECT iv.id_municipio, iv.mes, SUM(iv.noches_disponibles) AS noches
     FROM v_inventario_noche iv
    WHERE iv.anio = :anio
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
 ORDER BY municipio
"""

INGRESOS_ROLLUP = """
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
       GROUPING_ID(m.nombre, ta.nombre, t.tipo)         AS nivel
  FROM v_noche_vendida  nv
  JOIN municipio        m  ON m.id_municipio = nv.id_municipio
  JOIN tipo_alojamiento ta ON ta.id_tipo     = nv.id_tipo
  JOIN temporada        t  ON t.id_temporada = nv.id_temporada
 WHERE nv.anio = :anio
 GROUP BY ROLLUP (m.nombre, ta.nombre, t.tipo)
 ORDER BY GROUPING_ID(m.nombre, ta.nombre, t.tipo),
          m.nombre, ta.nombre, t.tipo
"""

TOP3_RANK = """
WITH ingresos AS (
   SELECT nv.id_municipio,
          nv.id_alojamiento,
          SUM(nv.valor_noche) AS ingreso,
          COUNT(*)            AS noches
     FROM v_noche_vendida nv
    WHERE nv.anio = :anio
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
 ORDER BY m.nombre, r.puesto
"""

VARIACION_LAG = """
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
       LAG(ingreso, 12) OVER (ORDER BY anio_mes)               AS ingreso_anio_anterior
  FROM mensual
 ORDER BY anio_mes
"""

RANGO_FECHAS = """
SELECT m.nombre                     AS municipio,
       ta.nombre                    AS tipo_alojamiento,
       COUNT(DISTINCT nv.id_reserva) AS reservas,
       COUNT(*)                     AS noches_vendidas,
       SUM(nv.valor_noche)          AS ingreso,
       ROUND(AVG(nv.valor_noche))   AS tarifa_media
  FROM v_noche_vendida  nv
  JOIN municipio        m  ON m.id_municipio = nv.id_municipio
  JOIN tipo_alojamiento ta ON ta.id_tipo     = nv.id_tipo
 WHERE nv.fecha BETWEEN :fecha_ini AND :fecha_fin
 GROUP BY m.nombre, ta.nombre
 ORDER BY ingreso DESC
"""

OCUPACION_MV = """
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
 WHERE v.anio = :anio
 ORDER BY v.anio_mes, puesto_del_mes
"""

CALIFICACIONES_UNPIVOT = """
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
 ORDER BY municipio, promedio DESC
"""

ADR_REVPAR_LIBRE = """
WITH ingreso_mun AS (
   SELECT nv.id_municipio,
          COUNT(*)             AS noches_vendidas,
          SUM(nv.valor_noche)  AS ingreso,
          SUM(CASE WHEN t.tipo = 'ALTA' THEN nv.valor_noche ELSE 0 END) AS ingreso_alta
     FROM v_noche_vendida nv
     JOIN temporada t ON t.id_temporada = nv.id_temporada
    WHERE nv.anio = :anio
    GROUP BY nv.id_municipio
),
inventario_mun AS (
   SELECT id_municipio, SUM(noches_disponibles) AS noches_disponibles
     FROM v_inventario_noche
    WHERE anio = :anio
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
 ORDER BY puesto_revpar
"""

AUDITORIA_TARIFA = """
SELECT id_auditoria, fecha_hora, usuario_bd, operacion, id_tarifa,
       valor_anterior, valor_nuevo, filas_afectadas
  FROM auditoria_tarifa
 ORDER BY id_auditoria DESC
 FETCH FIRST 50 ROWS ONLY
"""

# Mismo cálculo del cursor explícito c_liq de pkg_turismo.sp_liquidar_mes
# (sql/10_pkg_turismo.sql), reescrito como SELECT directo porque esta
# pantalla es un reporte de solo lectura: no hace falta pasar por
# DBMS_OUTPUT para mostrarlo en una tabla HTML.
LIQUIDACION_MES = """
SELECT r.id_reserva,
       r.fecha_checkin,
       r.fecha_checkout,
       r.valor_total,
       NVL((SELECT SUM(pg.valor) FROM pago pg
             WHERE pg.id_reserva = r.id_reserva AND pg.estado = 'APROBADO'), 0) AS pagado
  FROM reserva r
 WHERE r.id_alojamiento = :id_alojamiento
   AND r.estado IN ('CONFIRMADA', 'COMPLETADA')
   AND EXTRACT(YEAR  FROM r.fecha_checkout) = :anio
   AND EXTRACT(MONTH FROM r.fecha_checkout) = :mes
 ORDER BY r.fecha_checkout
"""

MUNICIPIOS = "SELECT id_municipio, nombre FROM municipio ORDER BY nombre"

ALOJAMIENTOS = """
SELECT a.id_alojamiento, a.nombre, m.nombre AS municipio
  FROM alojamiento a JOIN municipio m ON m.id_municipio = a.id_municipio
 WHERE a.activo = 'S'
 ORDER BY m.nombre, a.nombre
"""

HABITACIONES_DE_ALOJAMIENTO = """
SELECT id_habitacion, numero, categoria, capacidad
  FROM habitacion
 WHERE id_alojamiento = :id_alojamiento
   AND activa = 'S'
 ORDER BY numero
"""

# Tarifas de un alojamiento, para la pantalla de edición. Editar valor_noche
# desde ahí dispara trg_tarifa_auditoria (disparador de sentencia) igual que
# cualquier otro UPDATE sobre TARIFA, sin necesidad de ningún código extra.
TARIFAS_DE_ALOJAMIENTO = """
SELECT t.id_tarifa, c.descripcion AS categoria, te.nombre AS temporada,
       te.tipo, t.valor_noche
  FROM tarifa t
  JOIN categoria_habitacion c ON c.codigo       = t.categoria
  JOIN temporada            te ON te.id_temporada = t.id_temporada
 WHERE t.id_alojamiento = :id_alojamiento
 ORDER BY te.fecha_inicio, c.codigo
"""

CLIENTE_POR_DOCUMENTO = """
SELECT id_cliente, nombres, apellidos
  FROM cliente
 WHERE tipo_documento = :tipo_documento
   AND numero_documento = :numero_documento
"""

# INSERT directo (no hay regla de negocio que justifique pasar esto por un
# procedimiento del paquete): registra un cliente nuevo cuando la búsqueda
# por documento no encuentra ninguno, para poder seguir con la reserva.
CLIENTE_INSERT = """
INSERT INTO cliente (tipo_documento, numero_documento, nombres, apellidos,
                     email, telefono, fecha_nacimiento, pais, ciudad_origen)
VALUES (:tipo_documento, :numero_documento, :nombres, :apellidos,
        :email, :telefono, TO_DATE(:fecha_nacimiento, 'YYYY-MM-DD'),
        NVL(:pais, 'Colombia'), :ciudad_origen)
RETURNING id_cliente INTO :id_cliente
"""

RESERVAS_RECIENTES = """
SELECT r.id_reserva, c.nombres || ' ' || c.apellidos AS cliente,
       a.nombre AS alojamiento, r.fecha_checkin, r.fecha_checkout,
       r.estado, r.valor_total
  FROM reserva r
  JOIN cliente c ON c.id_cliente = r.id_cliente
  JOIN alojamiento a ON a.id_alojamiento = r.id_alojamiento
 ORDER BY r.id_reserva DESC
 FETCH FIRST 20 ROWS ONLY
"""
