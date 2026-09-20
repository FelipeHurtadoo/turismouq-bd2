-- =====================================================================
-- TurismoUQ · 06_carga_masiva.sql
-- Ejecutar como: TURISMO_UQ
--
-- Volúmenes exigidos por el documento:
--   60 alojamientos · 400 habitaciones · 3.000 clientes
--   25.000 reservas (2024-2026) · 40.000 líneas de servicios
--
-- Principios de la generación:
--   1. Coherencia antes que aleatoriedad: toda FK apunta a una fila existente.
--   2. Cero violaciones de constraints: las fechas, capacidades y valores se
--      construyen dentro de los rangos que el DDL permite.
--   3. SIN SOLAPAMIENTOS: un mapa de ocupación en memoria impide que dos
--      reservas usen la misma habitación la misma noche. Esto es lo que hará
--      que el disparador de fila de la Entrega 2 sea coherente con los datos
--      ya cargados.
--   4. Estacionalidad real: el 55 % de los check-in caen en días de temporada
--      ALTA o MEDIA, de modo que las consultas analíticas muestren picos.
--
-- Semilla fija (DBMS_RANDOM.SEED) para que la carga sea REPRODUCIBLE.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET TIMING ON
SET DEFINE OFF

-- =====================================================================
-- BLOQUE A · 60 alojamientos, 400 habitaciones y sus tarifas
-- =====================================================================
DECLARE
   TYPE t_vc IS VARRAY(40) OF VARCHAR2(40);
   v_pre  t_vc := t_vc('Finca','Hacienda','Hotel','Glamping','Hostal','Cabañas',
                       'Posada','Casa','Refugio','Mirador','Reserva','Villa');
   v_nom  t_vc := t_vc('El Cafetal','La Palma','Los Guaduales','Buenos Aires',
                       'El Mirador','La Esperanza','San José','Alto Bonito',
                       'El Yarumo','La Cristalina','Portal del Quindío',
                       'Camino Real','La Colina','El Bambú','Sol de Oriente',
                       'La Cascada','El Ocaso','Bellavista','La Aurora','Guayacán');
   v_via  t_vc := t_vc('Vereda La Julia','Km 3 vía Armenia','Calle 12 # 14-30',
                       'Km 5 vía Pereira','Vereda El Castillo','Carrera 6 # 4-18',
                       'Km 2 vía Cocora','Vereda Buenavista','Calle 8 # 3-45',
                       'Km 7 vía Montenegro');

   TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
   v_mun_id   t_num;          -- ids de municipio
   v_mun_peso t_num;          -- peso turístico acumulado
   v_tipo_id  t_num;
   v_aloj_id  t_num;
   v_cuartos  t_num;          -- habitaciones por alojamiento
   v_base     t_num;          -- precio base por alojamiento

   v_tot_mun  PLS_INTEGER;
   v_tot_tipo PLS_INTEGER;
   v_r        NUMBER;
   v_idx      PLS_INTEGER;
   v_id       NUMBER;
   v_rest     PLS_INTEGER;
   v_cat      VARCHAR2(20);
   v_cap      NUMBER;
   v_nhab     PLS_INTEGER := 0;
   -- Escalares intermedios: una colección declarada DENTRO del bloque PL/SQL
   -- no puede referenciarse desde una sentencia SQL (PLS-00425). Se extrae el
   -- elemento a una variable y se usa la variable en el INSERT.
   v_nom_alo  VARCHAR2(200);
   v_dir      VARCHAR2(150);
   v_idmun    NUMBER;
   v_idtipo   NUMBER;
   v_ntar     PLS_INTEGER := 0;
BEGIN
   DBMS_RANDOM.SEED(20262);

   SELECT id_municipio BULK COLLECT INTO v_mun_id FROM municipio ORDER BY id_municipio;
   SELECT id_tipo      BULK COLLECT INTO v_tipo_id FROM tipo_alojamiento ORDER BY id_tipo;
   v_tot_mun  := v_mun_id.COUNT;
   v_tot_tipo := v_tipo_id.COUNT;

   -- Pesos turísticos: Salento, Armenia, Montenegro, Quimbaya y Calarcá
   -- concentran la oferta real; Génova, Pijao, Córdoba y Buenavista son
   -- destinos pequeños. El orden alfabético de la carga es:
   -- 1 Armenia 2 Buenavista 3 Calarcá 4 Circasia 5 Córdoba 6 Filandia
   -- 7 Génova 8 La Tebaida 9 Montenegro 10 Pijao 11 Quimbaya 12 Salento
   v_mun_peso(1) := 12; v_mun_peso(2) := 2;  v_mun_peso(3) := 9;
   v_mun_peso(4) := 5;  v_mun_peso(5) := 2;  v_mun_peso(6) := 7;
   v_mun_peso(7) := 1;  v_mun_peso(8) := 5;  v_mun_peso(9) := 8;
   v_mun_peso(10):= 2;  v_mun_peso(11):= 7;  v_mun_peso(12):= 12;

   -- ---- 60 alojamientos ------------------------------------------------
   -- Los primeros 12 se reparten uno por municipio, para GARANTIZAR que los
   -- 12 municipios del Quindío tengan oferta y aparezcan en las consultas de
   -- análisis. Sin esto, la ruleta ponderada puede dejar sin alojamientos a un
   -- municipio de peso bajo (Buenavista, Génova, Pijao) y el PIVOT devolvería
   -- 11 filas en lugar de 12.
   -- Los 48 restantes sí se sortean por peso turístico.
   FOR i IN 1 .. 60 LOOP
      IF i <= v_tot_mun THEN
         v_idx := i;                       -- cobertura garantizada
      ELSE
         -- municipio por ruleta ponderada
         v_r := DBMS_RANDOM.VALUE(0, 72);   -- 72 = suma de los pesos
         v_idx := 1;
         WHILE v_idx < v_tot_mun AND v_r > v_mun_peso(v_idx) LOOP
            v_r := v_r - v_mun_peso(v_idx);
            v_idx := v_idx + 1;
         END LOOP;
      END IF;

      v_id := seq_alojamiento.NEXTVAL;
      v_aloj_id(i) := v_id;

      v_idmun  := v_mun_id(v_idx);
      v_idtipo := v_tipo_id(TRUNC(DBMS_RANDOM.VALUE(1, v_tot_tipo + 1)));
      v_nom_alo := v_pre(TRUNC(DBMS_RANDOM.VALUE(1, v_pre.COUNT + 1))) || ' ' ||
                   v_nom(TRUNC(DBMS_RANDOM.VALUE(1, v_nom.COUNT + 1))) || ' ' || i;
      v_dir     := v_via(TRUNC(DBMS_RANDOM.VALUE(1, v_via.COUNT + 1)));

      INSERT INTO alojamiento (id_alojamiento, id_municipio, id_tipo, nombre,
                               direccion, telefono, email, estrellas,
                               fecha_registro, activo)
      VALUES (v_id,
              v_idmun,
              v_idtipo,
              v_nom_alo,
              v_dir,
              '60' || TRUNC(DBMS_RANDOM.VALUE(6000000, 7999999)),
              'contacto' || i || '@turismouq.co',
              TRUNC(DBMS_RANDOM.VALUE(2, 6)),
              DATE '2023-01-01' + TRUNC(DBMS_RANDOM.VALUE(0, 330)),
              'S');

      v_cuartos(i) := 4;                                   -- piso mínimo
      v_base(i)    := TRUNC(DBMS_RANDOM.VALUE(90, 320)) * 1000;  -- COP/noche base
   END LOOP;

   -- ---- repartir las 160 habitaciones restantes hasta llegar a 400 ------
   v_rest := 400 - 60 * 4;
   WHILE v_rest > 0 LOOP
      v_idx := TRUNC(DBMS_RANDOM.VALUE(1, 61));
      IF v_cuartos(v_idx) < 16 THEN
         v_cuartos(v_idx) := v_cuartos(v_idx) + 1;
         v_rest := v_rest - 1;
      END IF;
   END LOOP;

   -- ---- habitaciones ----------------------------------------------------
   FOR i IN 1 .. 60 LOOP
      v_id := v_aloj_id(i);
      FOR n IN 1 .. v_cuartos(i) LOOP
         v_r := DBMS_RANDOM.VALUE;
         IF    v_r < 0.60 THEN v_cat := 'ESTANDAR'; v_cap := TRUNC(DBMS_RANDOM.VALUE(2, 4));
         ELSIF v_r < 0.88 THEN v_cat := 'SUPERIOR'; v_cap := TRUNC(DBMS_RANDOM.VALUE(2, 5));
         ELSE                  v_cat := 'SUITE';    v_cap := TRUNC(DBMS_RANDOM.VALUE(4, 7));
         END IF;

         INSERT INTO habitacion (id_alojamiento, numero, categoria, capacidad, activa)
         VALUES (v_id,
                 TO_CHAR(100 * (1 + TRUNC((n-1)/10)) + MOD(n-1,10) + 1),
                 v_cat, v_cap, 'S');
         v_nhab := v_nhab + 1;
      END LOOP;
   END LOOP;

   COMMIT;
   DBMS_OUTPUT.PUT_LINE('Alojamientos: 60   Habitaciones: ' || v_nhab);

   -- ---- tarifas: alojamiento x categoría x temporada ---------------------
   -- El precio final es base * factor_categoria * factor_temporada, con un
   -- ruido de +/- 5 % redondeado a miles de pesos.
   FOR i IN 1 .. 60 LOOP
      v_id := v_aloj_id(i);
      v_cap := v_base(i);                       -- reutilizada como precio base
      FOR c IN (SELECT codigo, factor_precio FROM categoria_habitacion ORDER BY codigo) LOOP
         INSERT INTO tarifa (id_alojamiento, categoria, id_temporada, valor_noche)
         SELECT v_id, c.codigo, t.id_temporada,
                ROUND(v_cap * c.factor_precio * t.factor
                      * (0.95 + DBMS_RANDOM.VALUE * 0.10), -3)
           FROM temporada t;
         v_ntar := v_ntar + SQL%ROWCOUNT;
      END LOOP;
      IF MOD(i, 10) = 0 THEN COMMIT; END IF;
   END LOOP;

   COMMIT;
   DBMS_OUTPUT.PUT_LINE('Tarifas: ' || v_ntar);
END;
/

-- =====================================================================
-- BLOQUE B · 3.000 clientes y usuarios del sistema
-- =====================================================================
DECLARE
   TYPE t_vc IS VARRAY(40) OF VARCHAR2(30);
   v_nomh t_vc := t_vc('Juan','Carlos','Andrés','Felipe','Santiago','Mateo',
                       'Sebastián','Julián','David','Camilo','Óscar','Iván');
   v_nomm t_vc := t_vc('María','Laura','Valentina','Daniela','Paula','Sofía',
                       'Catalina','Andrea','Luisa','Natalia','Carolina','Diana');
   v_ape  t_vc := t_vc('Gómez','Ramírez','Londoño','Hurtado','Cardona','Osorio',
                       'Restrepo','Betancur','Zuluaga','Arango','Muñoz','Grisales',
                       'Valencia','Ospina','Salazar','Marín','Quintero','Bedoya');
   v_ciu  t_vc := t_vc('Bogotá','Medellín','Cali','Pereira','Manizales',
                       'Barranquilla','Bucaramanga','Ibagué','Armenia','Cartagena');
   v_pais t_vc := t_vc('Colombia','Colombia','Colombia','Colombia','Colombia',
                       'Colombia','Colombia','Estados Unidos','España','Argentina',
                       'México','Brasil');
   v_nombre VARCHAR2(60);
   v_ap     VARCHAR2(60);
   v_id     NUMBER;
   -- Escalares intermedios: las colecciones locales no pueden usarse dentro
   -- de una sentencia SQL (PLS-00425).
   v_pa     VARCHAR2(40);
   v_ciudad VARCHAR2(60);
   v_tdoc   VARCHAR2(3);
   v_r      NUMBER;
BEGIN
   DBMS_RANDOM.SEED(77301);

   FOR i IN 1 .. 3000 LOOP
      IF DBMS_RANDOM.VALUE < 0.5 THEN
         v_nombre := v_nomh(TRUNC(DBMS_RANDOM.VALUE(1, v_nomh.COUNT + 1)));
      ELSE
         v_nombre := v_nomm(TRUNC(DBMS_RANDOM.VALUE(1, v_nomm.COUNT + 1)));
      END IF;
      v_ap := v_ape(TRUNC(DBMS_RANDOM.VALUE(1, v_ape.COUNT + 1))) || ' ' ||
              v_ape(TRUNC(DBMS_RANDOM.VALUE(1, v_ape.COUNT + 1)));
      v_id := seq_cliente.NEXTVAL;

      v_pa     := v_pais(TRUNC(DBMS_RANDOM.VALUE(1, v_pais.COUNT + 1)));
      v_ciudad := v_ciu(TRUNC(DBMS_RANDOM.VALUE(1, v_ciu.COUNT + 1)));
      v_r      := DBMS_RANDOM.VALUE;
      v_tdoc   := CASE WHEN v_r < 0.90 THEN 'CC'
                       WHEN v_r < 0.96 THEN 'CE'
                       ELSE 'PAS' END;

      -- Documento y correo se construyen con el id => unicidad garantizada,
      -- sin colisiones que aborten la carga. Datos ficticios, no reales.
      INSERT INTO cliente (id_cliente, tipo_documento, numero_documento,
                           nombres, apellidos, email, telefono,
                           fecha_nacimiento, pais, ciudad_origen, fecha_registro)
      VALUES (v_id,
              v_tdoc,
              TO_CHAR(1000000000 + v_id * 7 + TRUNC(DBMS_RANDOM.VALUE(0,6))),
              v_nombre, v_ap,
              'cliente' || v_id || '@correo-demo.co',
              '3' || TRUNC(DBMS_RANDOM.VALUE(100000000, 299999999)),
              DATE '1995-01-01' - TRUNC(DBMS_RANDOM.VALUE(0, 14600)),
              v_pa,
              v_ciudad,
              DATE '2023-06-01' + TRUNC(DBMS_RANDOM.VALUE(0, 900)));

      IF MOD(i, 500) = 0 THEN COMMIT; END IF;
   END LOOP;
   COMMIT;
   DBMS_OUTPUT.PUT_LINE('Clientes: 3000');

   -- Usuarios del sistema: 1 recepción + 1 administrador por alojamiento,
   -- más 3 gerentes y 2 auditores (roles transversales de la Entrega 3).
   FOR a IN (SELECT id_alojamiento FROM alojamiento ORDER BY id_alojamiento) LOOP
      INSERT INTO usuario_sistema (username, nombre_completo, email, rol, id_alojamiento)
      VALUES ('recep' || a.id_alojamiento, 'Recepción alojamiento ' || a.id_alojamiento,
              'recep' || a.id_alojamiento || '@turismouq.co', 'RECEPCION', a.id_alojamiento);
      INSERT INTO usuario_sistema (username, nombre_completo, email, rol, id_alojamiento)
      VALUES ('admin' || a.id_alojamiento, 'Administrador alojamiento ' || a.id_alojamiento,
              'admin' || a.id_alojamiento || '@turismouq.co', 'ADMIN_ALOJAMIENTO', a.id_alojamiento);
   END LOOP;
   FOR i IN 1 .. 3 LOOP
      INSERT INTO usuario_sistema (username, nombre_completo, email, rol, id_alojamiento)
      VALUES ('gerente' || i, 'Gerente regional ' || i,
              'gerente' || i || '@turismouq.co', 'GERENTE', NULL);
   END LOOP;
   FOR i IN 1 .. 2 LOOP
      INSERT INTO usuario_sistema (username, nombre_completo, email, rol, id_alojamiento)
      VALUES ('auditor' || i, 'Auditor interno ' || i,
              'auditor' || i || '@turismouq.co', 'AUDITOR', NULL);
   END LOOP;
   COMMIT;
   DBMS_OUTPUT.PUT_LINE('Usuarios del sistema: 125');
END;
/

-- =====================================================================
-- BLOQUE C · 25.000 reservas + líneas de RESERVA_HABITACION
-- =====================================================================
DECLARE
   c_base   CONSTANT DATE        := DATE '2024-01-01';
   c_dias   CONSTANT PLS_INTEGER := 1096;
   c_meta   CONSTANT PLS_INTEGER := 25000;

   TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
   TYPE t_chr IS TABLE OF CHAR(1) INDEX BY PLS_INTEGER;

   v_hab_id   t_num;  v_hab_cap t_num;  v_hab_alo t_num;   -- habitaciones ordenadas
   v_ini      t_num;  v_cnt     t_num;                     -- rango de cada alojamiento
   v_aloj     t_num;                                        -- ids de alojamiento
   v_cli      t_num;                                        -- ids de cliente
   v_peak     t_num;                                        -- días ALTA/MEDIA
   v_ocup     t_chr;                                        -- mapa de ocupación
   v_idcli    NUMBER;
   v_idhab    NUMBER;
   v_huesp    NUMBER;

   v_sel      t_num;                                        -- habitaciones elegidas
   v_ok       PLS_INTEGER := 0;
   v_try      PLS_INTEGER := 0;
   v_a        NUMBER;
   v_pos      PLS_INTEGER;
   v_off      PLS_INTEGER;
   v_noches   PLS_INTEGER;
   v_nhab     PLS_INTEGER;
   v_found    PLS_INTEGER;
   v_libre    BOOLEAN;
   v_capt     NUMBER;
   v_idres    NUMBER;
   v_ci       DATE;
   v_co       DATE;
   v_estado   VARCHAR2(15);
   v_r        NUMBER;
   v_start    PLS_INTEGER;
   v_hoy      DATE := TRUNC(SYSDATE);
BEGIN
   DBMS_RANDOM.SEED(1907);

   -- Habitaciones ordenadas por alojamiento: permite tratar cada alojamiento
   -- como un segmento contiguo del arreglo (v_ini .. v_ini+v_cnt-1).
   SELECT id_habitacion, capacidad, id_alojamiento
     BULK COLLECT INTO v_hab_id, v_hab_cap, v_hab_alo
     FROM habitacion
    WHERE activa = 'S'
    ORDER BY id_alojamiento, id_habitacion;

   FOR i IN 1 .. v_hab_id.COUNT LOOP
      v_a := v_hab_alo(i);
      IF NOT v_ini.EXISTS(v_a) THEN
         v_ini(v_a) := i;
         v_cnt(v_a) := 0;
      END IF;
      v_cnt(v_a) := v_cnt(v_a) + 1;
   END LOOP;

   SELECT id_alojamiento BULK COLLECT INTO v_aloj FROM alojamiento ORDER BY id_alojamiento;
   SELECT id_cliente     BULK COLLECT INTO v_cli  FROM cliente     ORDER BY id_cliente;

   -- Días de temporada ALTA/MEDIA, para sesgar la demanda hacia ellos.
   SELECT d.fecha - c_base BULK COLLECT INTO v_peak
     FROM dim_tiempo d
     JOIN temporada t ON t.id_temporada = d.id_temporada
    WHERE t.tipo IN ('ALTA','MEDIA');

   WHILE v_ok < c_meta AND v_try < 400000 LOOP
      v_try := v_try + 1;

      -- 1) alojamiento
      v_a := v_aloj(TRUNC(DBMS_RANDOM.VALUE(1, v_aloj.COUNT + 1)));

      -- 2) fecha de entrada (55 % en temporada alta/media)
      IF DBMS_RANDOM.VALUE < 0.55 THEN
         v_off := v_peak(TRUNC(DBMS_RANDOM.VALUE(1, v_peak.COUNT + 1)));
      ELSE
         v_off := TRUNC(DBMS_RANDOM.VALUE(0, c_dias));
      END IF;

      -- 3) noches: 1 a 7, concentradas en 2-4
      v_r := DBMS_RANDOM.VALUE;
      v_noches := CASE WHEN v_r < 0.12 THEN 1
                       WHEN v_r < 0.42 THEN 2
                       WHEN v_r < 0.70 THEN 3
                       WHEN v_r < 0.86 THEN 4
                       WHEN v_r < 0.94 THEN 5
                       WHEN v_r < 0.98 THEN 6
                       ELSE 7 END;

      IF v_off + v_noches > c_dias THEN
         GOTO siguiente;                       -- la estadía se saldría de 2026
      END IF;

      -- 4) cuántas habitaciones
      v_nhab := CASE WHEN DBMS_RANDOM.VALUE < 0.85 THEN 1 ELSE 2 END;
      IF v_cnt(v_a) < v_nhab THEN GOTO siguiente; END IF;

      -- 5) buscar habitaciones libres TODAS las noches del rango
      v_found := 0;
      v_sel.DELETE;
      v_start := TRUNC(DBMS_RANDOM.VALUE(0, v_cnt(v_a)));
      FOR k IN 0 .. v_cnt(v_a) - 1 LOOP
         v_pos := v_ini(v_a) + MOD(v_start + k, v_cnt(v_a));
         v_libre := TRUE;
         FOR d IN 0 .. v_noches - 1 LOOP
            IF v_ocup.EXISTS(v_pos * 1200 + v_off + d) THEN
               v_libre := FALSE;
               EXIT;
            END IF;
         END LOOP;
         IF v_libre THEN
            v_found := v_found + 1;
            v_sel(v_found) := v_pos;
            EXIT WHEN v_found = v_nhab;
         END IF;
      END LOOP;

      IF v_found < v_nhab THEN GOTO siguiente; END IF;

      -- 6) insertar la cabecera
      v_ci := c_base + v_off;
      v_co := v_ci + v_noches;

      v_capt := 0;
      FOR j IN 1 .. v_found LOOP
         v_capt := v_capt + v_hab_cap(v_sel(j));
      END LOOP;

      -- Estado coherente con el momento: lo que ya pasó está completado o
      -- cancelado; lo que está por venir está confirmado o pendiente.
      v_r := DBMS_RANDOM.VALUE;
      IF v_co < v_hoy THEN
         v_estado := CASE WHEN v_r < 0.88 THEN 'COMPLETADA'
                          WHEN v_r < 0.96 THEN 'CANCELADA'
                          ELSE 'NO_SHOW' END;
      ELSE
         v_estado := CASE WHEN v_r < 0.80 THEN 'CONFIRMADA'
                          WHEN v_r < 0.95 THEN 'PENDIENTE'
                          ELSE 'CANCELADA' END;
      END IF;

      v_idres := seq_reserva.NEXTVAL;
      v_idcli := v_cli(TRUNC(DBMS_RANDOM.VALUE(1, v_cli.COUNT + 1)));

      INSERT INTO reserva (id_reserva, id_cliente, id_alojamiento, fecha_reserva,
                           fecha_checkin, fecha_checkout, num_huespedes,
                           estado, canal, valor_alojamiento, valor_servicios)
      VALUES (v_idres,
              v_idcli,
              v_a,
              GREATEST(DATE '2023-10-01', v_ci - TRUNC(DBMS_RANDOM.VALUE(1, 91))),
              v_ci, v_co,
              GREATEST(1, TRUNC(DBMS_RANDOM.VALUE(1, v_capt + 1))),
              v_estado,
              CASE WHEN DBMS_RANDOM.VALUE < 0.55 THEN 'WEB'
                   WHEN DBMS_RANDOM.VALUE < 0.55 THEN 'AGENCIA'
                   WHEN DBMS_RANDOM.VALUE < 0.60 THEN 'TELEFONO'
                   ELSE 'PRESENCIAL' END,
              0, 0);

      -- 7) líneas de habitación + marcado del mapa de ocupación
      FOR j IN 1 .. v_found LOOP
         v_idhab := v_hab_id(v_sel(j));
         v_huesp := GREATEST(1, LEAST(v_hab_cap(v_sel(j)),
                             TRUNC(DBMS_RANDOM.VALUE(1, v_hab_cap(v_sel(j)) + 1))));
         INSERT INTO reserva_habitacion (id_reserva, id_habitacion, huespedes, valor_noches)
         VALUES (v_idres, v_idhab, v_huesp, 0);
         FOR d IN 0 .. v_noches - 1 LOOP
            v_ocup(v_sel(j) * 1200 + v_off + d) := 'X';
         END LOOP;
      END LOOP;

      v_ok := v_ok + 1;
      IF MOD(v_ok, 2000) = 0 THEN
         COMMIT;
         DBMS_OUTPUT.PUT_LINE('  reservas insertadas: ' || v_ok);
      END IF;

      <<siguiente>>
      NULL;
   END LOOP;

   COMMIT;
   DBMS_OUTPUT.PUT_LINE('Reservas: ' || v_ok || '  (intentos: ' || v_try || ')');
   IF v_ok < c_meta THEN
      RAISE_APPLICATION_ERROR(-20001,
         'No se alcanzó el volumen mínimo de reservas: ' || v_ok);
   END IF;
END;
/

-- =====================================================================
-- BLOQUE D · Valoración de las estadías  (LA CONSULTA CLAVE DEL PROYECTO)
-- =====================================================================
-- Aquí se resuelve, en SQL puro, el problema que el documento señala como el
-- más difícil: una estadía que ATRAVIESA VARIAS TEMPORADAS.
--
-- Mecánica: cada noche de la estadía es una fila de DIM_TIEMPO; cada fila
-- conoce su temporada; con (alojamiento, categoría, temporada) se obtiene la
-- tarifa de ESA noche. Sumar por línea de reserva_habitacion da el valor
-- correcto aunque la estadía cruce dos, tres o diez temporadas.
--
-- El JOIN es d.fecha >= checkin AND d.fecha < checkout: la noche de salida
-- NO se cobra. Un rango [checkin, checkout) de 3 días son 3 noches.
--
-- fn_valor_estadia (Entrega 2) será exactamente esta lógica encapsulada.
-- =====================================================================
MERGE INTO reserva_habitacion rh
USING (
   SELECT rh2.id_reserva_habitacion AS id,
          SUM(t.valor_noche)        AS valor
     FROM reserva_habitacion rh2
     JOIN reserva     r ON r.id_reserva     = rh2.id_reserva
     JOIN habitacion  h ON h.id_habitacion  = rh2.id_habitacion
     JOIN dim_tiempo  d ON d.fecha >= r.fecha_checkin
                       AND d.fecha <  r.fecha_checkout
     JOIN tarifa      t ON t.id_alojamiento = h.id_alojamiento
                       AND t.categoria      = h.categoria
                       AND t.id_temporada   = d.id_temporada
    GROUP BY rh2.id_reserva_habitacion
) x
   ON (rh.id_reserva_habitacion = x.id)
WHEN MATCHED THEN UPDATE SET rh.valor_noches = x.valor;

COMMIT;

UPDATE reserva r
   SET r.valor_alojamiento = (SELECT NVL(SUM(rh.valor_noches), 0)
                                FROM reserva_habitacion rh
                               WHERE rh.id_reserva = r.id_reserva);
COMMIT;

-- Control: ninguna reserva puede quedar en cero
SELECT COUNT(*) AS reservas_sin_valor FROM reserva WHERE valor_alojamiento = 0;

-- =====================================================================
-- BLOQUE E · Pagos
-- =====================================================================
-- Decisión de diseño: el pago generado cubre el ALOJAMIENTO (los servicios
-- se cargan a la habitación y se liquidan al check-out, por eso este bloque
-- se ejecuta antes del bloque F). Por lo tanto, en los datos de prueba:
--    SUM(pago.valor APROBADO)  <=  SUM(reserva.valor_total)
-- Esa diferencia es intencional y es lo que la liquidación mensual por
-- alojamiento (cursor de la Entrega 2) tendrá que conciliar.
-- =====================================================================
DECLARE
   v_i     PLS_INTEGER := 0;
   v_idpg  NUMBER;
   v_med   VARCHAR2(20);
   v_v     NUMBER;

   -- El medio de pago se resuelve en PL/SQL y se pasa como variable:
   -- una función local NO puede invocarse desde una sentencia SQL estática.
   PROCEDURE nuevo_pago(p_reserva NUMBER, p_fecha DATE, p_valor NUMBER,
                        p_estado VARCHAR2) IS
      v_id  NUMBER := seq_pago.NEXTVAL;
      v_rnd NUMBER := DBMS_RANDOM.VALUE;
      v_m   VARCHAR2(20);
   BEGIN
      v_m := CASE WHEN v_rnd < 0.35 THEN 'TARJETA_CREDITO'
                  WHEN v_rnd < 0.55 THEN 'PSE'
                  WHEN v_rnd < 0.72 THEN 'TRANSFERENCIA'
                  WHEN v_rnd < 0.88 THEN 'TARJETA_DEBITO'
                  ELSE 'EFECTIVO' END;
      INSERT INTO pago (id_pago, id_reserva, fecha_pago, valor,
                        medio_pago, estado, referencia)
      VALUES (v_id, p_reserva, p_fecha, p_valor, v_m, p_estado,
              'PG-' || LPAD(v_id, 10, '0'));
   END;
BEGIN
   DBMS_RANDOM.SEED(4242);

   FOR r IN (SELECT id_reserva, estado, fecha_reserva, fecha_checkin, valor_total
               FROM reserva ORDER BY id_reserva) LOOP

      IF r.valor_total > 0 THEN
         IF r.estado IN ('CONFIRMADA','COMPLETADA','NO_SHOW') THEN
            IF DBMS_RANDOM.VALUE < 0.70 THEN
               nuevo_pago(r.id_reserva, r.fecha_reserva, r.valor_total, 'APROBADO');
            ELSE
               -- anticipo del 50 % + saldo el día del check-in
               v_v := ROUND(r.valor_total * 0.5, 2);
               nuevo_pago(r.id_reserva, r.fecha_reserva, v_v, 'APROBADO');
               nuevo_pago(r.id_reserva, r.fecha_checkin, r.valor_total - v_v, 'APROBADO');
            END IF;
         ELSIF r.estado = 'CANCELADA' AND DBMS_RANDOM.VALUE < 0.40 THEN
            -- se había pagado el anticipo y se reversó
            nuevo_pago(r.id_reserva, r.fecha_reserva,
                       ROUND(r.valor_total * 0.5, 2), 'REVERSADO');
         END IF;
      END IF;

      v_i := v_i + 1;
      IF MOD(v_i, 2000) = 0 THEN COMMIT; END IF;
   END LOOP;
   COMMIT;
END;
/

SELECT COUNT(*) AS pagos FROM pago;

-- =====================================================================
-- BLOQUE F · 40.000 líneas de servicios
-- =====================================================================
DECLARE
   TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
   TYPE t_dat IS TABLE OF DATE   INDEX BY PLS_INTEGER;
   v_res   t_num;  v_ci t_dat;  v_co t_dat;
   v_srv   t_num;  v_pre t_num;
   v_k     PLS_INTEGER;
   v_s     PLS_INTEGER;
   v_dias  NUMBER;
   v_idres NUMBER;
   v_idsrv NUMBER;
   v_fec   DATE;
   v_val   NUMBER;
BEGIN
   DBMS_RANDOM.SEED(8801);

   SELECT id_reserva, fecha_checkin, fecha_checkout
     BULK COLLECT INTO v_res, v_ci, v_co
     FROM reserva
    WHERE estado IN ('CONFIRMADA','COMPLETADA')
    ORDER BY id_reserva;

   SELECT id_servicio, precio_base BULK COLLECT INTO v_srv, v_pre
     FROM servicio WHERE activo = 'S' ORDER BY id_servicio;

   FOR i IN 1 .. 40000 LOOP
      v_k := TRUNC(DBMS_RANDOM.VALUE(1, v_res.COUNT + 1));
      v_s := TRUNC(DBMS_RANDOM.VALUE(1, v_srv.COUNT + 1));
      v_dias  := v_co(v_k) - v_ci(v_k);
      v_idres := v_res(v_k);
      v_idsrv := v_srv(v_s);
      v_fec   := v_ci(v_k) + TRUNC(DBMS_RANDOM.VALUE(0, v_dias));  -- dentro de la estadía
      v_val   := ROUND(v_pre(v_s) * (0.95 + DBMS_RANDOM.VALUE * 0.20), -2);

      INSERT INTO reserva_servicio (id_reserva, id_servicio, fecha_servicio,
                                    cantidad, valor_unitario)
      VALUES (v_idres, v_idsrv, v_fec, TRUNC(DBMS_RANDOM.VALUE(1, 5)), v_val);

      IF MOD(i, 5000) = 0 THEN
         COMMIT;
         DBMS_OUTPUT.PUT_LINE('  servicios insertados: ' || i);
      END IF;
   END LOOP;
   COMMIT;
END;
/

UPDATE reserva r
   SET r.valor_servicios = NVL((SELECT SUM(rs.valor_total)
                                  FROM reserva_servicio rs
                                 WHERE rs.id_reserva = r.id_reserva), 0);
COMMIT;

-- =====================================================================
-- BLOQUE G · Reseñas (solo de estadías completadas)
-- =====================================================================
-- El filtro NO usa DBMS_RANDOM.VALUE en el WHERE: en un INSERT ... SELECT
-- Oracle puede evaluar esa función una sola vez para toda la sentencia, de
-- modo que el filtro descarta el conjunto entero o lo acepta entero.
-- MOD sobre la clave primaria selecciona el 45 % de forma determinista y
-- además hace la carga reproducible.
INSERT INTO resena (id_reserva, fecha_resena, calif_general, calif_limpieza,
                    calif_ubicacion, calif_servicio, calif_precio, comentario)
SELECT r.id_reserva,
       r.fecha_checkout + 1 + MOD(r.id_reserva, 10),
       LEAST(5, GREATEST(1, ROUND(4.2 + DBMS_RANDOM.NORMAL * 0.8))),
       LEAST(5, GREATEST(1, ROUND(4.3 + DBMS_RANDOM.NORMAL * 0.7))),
       LEAST(5, GREATEST(1, ROUND(4.4 + DBMS_RANDOM.NORMAL * 0.6))),
       LEAST(5, GREATEST(1, ROUND(4.1 + DBMS_RANDOM.NORMAL * 0.9))),
       LEAST(5, GREATEST(1, ROUND(3.9 + DBMS_RANDOM.NORMAL * 1.0))),
       CASE MOD(r.id_reserva, 6)
          WHEN 0 THEN 'Excelente atención y un paisaje increíble.'
          WHEN 1 THEN 'Muy buena relación calidad-precio, volveríamos.'
          WHEN 2 THEN 'La finca es hermosa, el desayuno podría mejorar.'
          WHEN 3 THEN 'Ubicación perfecta para recorrer el Quindío.'
          WHEN 4 THEN 'Habitación cómoda y muy limpia.'
          ELSE        'Buena experiencia en general.'
       END
  FROM reserva r
 WHERE r.estado = 'COMPLETADA'
   AND MOD(r.id_reserva, 100) < 45;

COMMIT;

-- =====================================================================
-- BLOQUE H · Estadísticas del optimizador
-- =====================================================================
-- Sin estadísticas frescas, los planes de la Entrega 3 no serían creíbles.
BEGIN
   DBMS_STATS.GATHER_SCHEMA_STATS(
      ownname          => USER,
      estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
      method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
      cascade          => TRUE);
END;
/

PROMPT === Resumen de la carga ===
SELECT 'MUNICIPIO' t, COUNT(*) n FROM municipio          UNION ALL
SELECT 'ALOJAMIENTO',   COUNT(*) FROM alojamiento        UNION ALL
SELECT 'HABITACION',    COUNT(*) FROM habitacion         UNION ALL
SELECT 'TEMPORADA',     COUNT(*) FROM temporada          UNION ALL
SELECT 'TARIFA',        COUNT(*) FROM tarifa             UNION ALL
SELECT 'CLIENTE',       COUNT(*) FROM cliente            UNION ALL
SELECT 'RESERVA',       COUNT(*) FROM reserva            UNION ALL
SELECT 'RESERVA_HABITACION', COUNT(*) FROM reserva_habitacion UNION ALL
SELECT 'PAGO',          COUNT(*) FROM pago               UNION ALL
SELECT 'RESERVA_SERVICIO', COUNT(*) FROM reserva_servicio UNION ALL
SELECT 'RESENA',        COUNT(*) FROM resena             UNION ALL
SELECT 'USUARIO_SISTEMA', COUNT(*) FROM usuario_sistema;

SET TIMING OFF
