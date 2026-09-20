-- =====================================================================
-- TurismoUQ · 05_carga_catalogos.sql
-- Ejecutar como: TURISMO_UQ
--
-- Carga determinista (sin aleatoriedad) de:
--   · 12 municipios reales del Quindío
--   · 6 tipos de alojamiento · 3 categorías de habitación · 15 servicios
--   · temporadas 2024-2026, disjuntas y sin huecos
--   · DIM_TIEMPO: 1.096 días, cada uno asociado a su temporada
-- =====================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF

-- ---------------------------------------------------------------------
-- 1) MUNICIPIOS (los 12 del departamento, con su código DANE real)
-- ---------------------------------------------------------------------
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Armenia',    '63001', 1483, 306000);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Buenavista', '63111', 1450,   2800);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Calarcá',    '63130', 1536,  78000);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Circasia',   '63190', 1800,  30000);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Córdoba',    '63212', 1600,   5300);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Filandia',   '63272', 1923,  13500);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Génova',     '63302', 1600,   7500);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('La Tebaida', '63401', 1183,  47000);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Montenegro', '63470', 1294,  42000);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Pijao',      '63548', 1721,   5900);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Quimbaya',   '63594', 1339,  36000);
INSERT INTO municipio (nombre, codigo_dane, altitud_msnm, poblacion) VALUES ('Salento',    '63690', 1895,   7800);

-- ---------------------------------------------------------------------
-- 2) TIPOS DE ALOJAMIENTO
-- ---------------------------------------------------------------------
INSERT INTO tipo_alojamiento (nombre, descripcion) VALUES ('FINCA_CAFETERA', 'Finca tradicional del Paisaje Cultural Cafetero con hospedaje');
INSERT INTO tipo_alojamiento (nombre, descripcion) VALUES ('HOTEL',          'Hotel urbano o rural con servicios completos');
INSERT INTO tipo_alojamiento (nombre, descripcion) VALUES ('GLAMPING',       'Camping de lujo con domos o burbujas');
INSERT INTO tipo_alojamiento (nombre, descripcion) VALUES ('HOSTAL',         'Alojamiento económico, habitaciones compartidas o privadas');
INSERT INTO tipo_alojamiento (nombre, descripcion) VALUES ('CABANA',         'Cabañas independientes en entorno rural');
INSERT INTO tipo_alojamiento (nombre, descripcion) VALUES ('APARTAHOTEL',    'Apartamentos con cocina y servicio hotelero');

-- ---------------------------------------------------------------------
-- 3) CATEGORÍAS DE HABITACIÓN
-- ---------------------------------------------------------------------
INSERT INTO categoria_habitacion (codigo, descripcion, factor_precio) VALUES ('ESTANDAR', 'Habitación estándar, baño privado',           1.00);
INSERT INTO categoria_habitacion (codigo, descripcion, factor_precio) VALUES ('SUPERIOR', 'Habitación superior con vista o balcón',      1.35);
INSERT INTO categoria_habitacion (codigo, descripcion, factor_precio) VALUES ('SUITE',    'Suite o cabaña familiar con sala y jacuzzi',  1.90);

-- ---------------------------------------------------------------------
-- 4) SERVICIOS COMPLEMENTARIOS (15)
-- ---------------------------------------------------------------------
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Desayuno típico quindiano',      'ALIMENTACION',  22000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Almuerzo bandeja paisa',         'ALIMENTACION',  38000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Cena a la carta',                'ALIMENTACION',  55000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Tour del café',                  'TOUR',          75000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Tour Valle de Cocora',           'TOUR',          95000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Avistamiento de aves',           'TOUR',         120000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Cabalgata guiada',               'RECREACION',    85000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Caminata ecológica',             'RECREACION',    45000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Clase de barismo',               'RECREACION',    65000, 'PERSONA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Transporte aeropuerto El Edén',  'TRANSPORTE',    70000, 'TRAYECTO');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Transporte a Parque del Café',   'TRANSPORTE',    50000, 'TRAYECTO');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Masaje relajante',               'BIENESTAR',     90000, 'SESION');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Acceso a jacuzzi privado',       'BIENESTAR',     60000, 'HORA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Alquiler de bicicleta',          'RECREACION',    30000, 'DIA');
INSERT INTO servicio (nombre, categoria, precio_base, unidad_medida) VALUES ('Lavandería',                     'OTRO',          25000, 'UNIDAD');

COMMIT;

-- ---------------------------------------------------------------------
-- 5) TEMPORADAS 2024-2026
-- ---------------------------------------------------------------------
-- Requisito del documento: "se dispara en Semana Santa, mitad de año, los
-- puentes festivos y diciembre-enero, y cae el resto del tiempo".
--
-- Decisión de diseño (reglas de clasificación):
--   ALTA  : 15 dic - 15 ene · Semana Santa (fecha real de cada año)
--           · 15 jun - 15 jul
--   MEDIA : bloque viernes-lunes de la segunda semana de cada mes
--           (aproximación reproducible de los puentes festivos colombianos)
--   BAJA  : todo lo demás
--
-- Algoritmo: se clasifica día por día en un arreglo asociativo y luego se
-- COMPRIMEN los días consecutivos del mismo tipo en filas de TEMPORADA.
-- Esto garantiza por construcción que las temporadas son DISJUNTAS y que
-- CUBREN el rango completo sin huecos: la propiedad que hace correcto el
-- cálculo de fn_valor_estadia en la Entrega 2.
--
-- Nota técnica: el día de la semana se calcula con
--    MOD(fecha - DATE '1900-01-01', 7)   -- 0 = lunes (1900-01-01 fue lunes)
-- en lugar de TO_CHAR(fecha,'D') o NEXT_DAY, que dependen de la
-- configuración NLS del cliente y harían el script no reproducible.
-- ---------------------------------------------------------------------
DECLARE
   c_ini   CONSTANT DATE := DATE '2024-01-01';
   c_fin   CONSTANT DATE := DATE '2026-12-31';
   c_dias  CONSTANT PLS_INTEGER := c_fin - c_ini + 1;   -- 1096

   TYPE t_tipo IS TABLE OF VARCHAR2(5) INDEX BY PLS_INTEGER;
   v_dia   t_tipo;

   TYPE t_fechas IS TABLE OF DATE;
   -- Semana Santa (domingo de resurrección: 2024-03-31, 2025-04-20, 2026-04-05)
   v_ss_ini t_fechas := t_fechas(DATE '2024-03-24', DATE '2025-04-13', DATE '2026-03-29');
   v_ss_fin t_fechas := t_fechas(DATE '2024-03-31', DATE '2025-04-20', DATE '2026-04-05');

   v_mes_ini DATE;
   v_viernes DATE;
   v_off     PLS_INTEGER;
   v_tipo_actual VARCHAR2(5);
   v_ini_bloque  DATE;
   v_factor  NUMBER;
   v_n       PLS_INTEGER := 0;

   PROCEDURE marcar(p_desde DATE, p_hasta DATE, p_tipo VARCHAR2) IS
   BEGIN
      FOR d IN GREATEST(p_desde, c_ini) - c_ini .. LEAST(p_hasta, c_fin) - c_ini LOOP
         v_dia(d) := p_tipo;
      END LOOP;
   END;
BEGIN
   -- 5.1 Todo empieza en BAJA
   FOR d IN 0 .. c_dias - 1 LOOP
      v_dia(d) := 'BAJA';
   END LOOP;

   -- 5.2 MEDIA: bloque viernes-lunes de la segunda semana de cada mes
   FOR k IN 0 .. 35 LOOP
      v_mes_ini := ADD_MONTHS(c_ini, k);
      -- primer viernes del mes: 4 = viernes en la numeración 0=lunes
      v_viernes := v_mes_ini + MOD(4 - MOD(v_mes_ini - DATE '1900-01-01', 7) + 7, 7);
      v_viernes := v_viernes + 7;                  -- segundo viernes
      marcar(v_viernes, v_viernes + 3, 'MEDIA');   -- viernes a lunes
   END LOOP;

   -- 5.3 ALTA (sobrescribe MEDIA y BAJA)
   FOR a IN 2024 .. 2026 LOOP
      -- mitad de año
      marcar(TO_DATE(a || '-06-15','YYYY-MM-DD'), TO_DATE(a || '-07-15','YYYY-MM-DD'), 'ALTA');
      -- fin de año y comienzo del siguiente
      marcar(TO_DATE(a || '-12-15','YYYY-MM-DD'), TO_DATE(a || '-12-31','YYYY-MM-DD'), 'ALTA');
      marcar(TO_DATE(a || '-01-01','YYYY-MM-DD'), TO_DATE(a || '-01-15','YYYY-MM-DD'), 'ALTA');
   END LOOP;
   FOR i IN 1 .. v_ss_ini.COUNT LOOP
      marcar(v_ss_ini(i), v_ss_fin(i), 'ALTA');    -- Semana Santa
   END LOOP;

   -- 5.4 Compresión de días consecutivos del mismo tipo -> filas de TEMPORADA
   v_tipo_actual := v_dia(0);
   v_ini_bloque  := c_ini;
   FOR d IN 1 .. c_dias LOOP
      IF d = c_dias OR v_dia(d) <> v_tipo_actual THEN
         v_factor := CASE v_tipo_actual
                        WHEN 'ALTA'  THEN 1.60
                        WHEN 'MEDIA' THEN 1.25
                        ELSE 1.00
                     END;
         INSERT INTO temporada (nombre, tipo, fecha_inicio, fecha_fin, factor)
         VALUES (v_tipo_actual || ' ' || TO_CHAR(v_ini_bloque,'YYYY-MM-DD'),
                 v_tipo_actual,
                 v_ini_bloque,
                 c_ini + d - 1,
                 v_factor);
         v_n := v_n + 1;
         IF d < c_dias THEN
            v_tipo_actual := v_dia(d);
            v_ini_bloque  := c_ini + d;
         END IF;
      END IF;
   END LOOP;

   COMMIT;
   DBMS_OUTPUT.PUT_LINE('Temporadas creadas: ' || v_n);
END;
/

-- ---------------------------------------------------------------------
-- 6) DIM_TIEMPO
-- ---------------------------------------------------------------------
-- El JOIN por rango contra TEMPORADA cumple una doble función:
--   a) puebla la FK id_temporada;
--   b) es la PRUEBA de que las temporadas cubren el rango sin huecos y sin
--      superposición: si faltara un día, se insertarían menos de 1.096 filas;
--      si dos temporadas se solaparan, se insertarían más y la PK fallaría.
-- ---------------------------------------------------------------------
INSERT INTO dim_tiempo
   (fecha, anio, mes, dia, anio_mes, nombre_mes, trimestre,
    dia_semana, es_fin_semana, id_temporada)
SELECT f.fecha,
       EXTRACT(YEAR  FROM f.fecha),
       EXTRACT(MONTH FROM f.fecha),
       EXTRACT(DAY   FROM f.fecha),
       TO_CHAR(f.fecha, 'YYYY-MM'),
       DECODE(EXTRACT(MONTH FROM f.fecha),
              1,'ENERO', 2,'FEBRERO', 3,'MARZO',     4,'ABRIL',
              5,'MAYO',  6,'JUNIO',   7,'JULIO',     8,'AGOSTO',
              9,'SEPTIEMBRE', 10,'OCTUBRE', 11,'NOVIEMBRE', 12,'DICIEMBRE'),
       TO_NUMBER(TO_CHAR(f.fecha,'Q')),
       MOD(f.fecha - DATE '1900-01-01', 7) + 1,                       -- 1=lunes
       CASE WHEN MOD(f.fecha - DATE '1900-01-01', 7) + 1 IN (6,7)
            THEN 'S' ELSE 'N' END,
       t.id_temporada
  FROM (SELECT DATE '2024-01-01' + LEVEL - 1 AS fecha
          FROM dual
        CONNECT BY LEVEL <= DATE '2026-12-31' - DATE '2024-01-01' + 1) f
  JOIN temporada t
    ON f.fecha BETWEEN t.fecha_inicio AND t.fecha_fin;

COMMIT;

-- ---------------------------------------------------------------------
-- 7) Verificación inmediata del catálogo
-- ---------------------------------------------------------------------
PROMPT === Catálogos cargados ===
SELECT 'MUNICIPIO' tabla, COUNT(*) filas FROM municipio            UNION ALL
SELECT 'TIPO_ALOJAMIENTO',  COUNT(*)     FROM tipo_alojamiento     UNION ALL
SELECT 'CATEGORIA_HABITACION', COUNT(*)  FROM categoria_habitacion UNION ALL
SELECT 'SERVICIO',          COUNT(*)     FROM servicio             UNION ALL
SELECT 'TEMPORADA',         COUNT(*)     FROM temporada            UNION ALL
SELECT 'DIM_TIEMPO (=1096)',COUNT(*)     FROM dim_tiempo;

PROMPT === Distribución de días por tipo de temporada ===
SELECT t.tipo, COUNT(*) AS dias,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
  FROM dim_tiempo d JOIN temporada t ON t.id_temporada = d.id_temporada
 GROUP BY t.tipo
 ORDER BY dias DESC;
