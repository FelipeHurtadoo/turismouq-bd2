-- =====================================================================
-- TurismoUQ · 10_pkg_turismo.sql
-- Ejecutar como: TURISMO_UQ
-- Oracle XE 21c
--
-- Entrega 2 · Capa PL/SQL. Paquete único que agrupa:
--   · fn_valor_estadia   : función (la más difícil del proyecto)
--   · sp_crear_reserva   : procedimiento con excepciones propias
--   · sp_liquidar_mes    : proceso masivo con cursor explícito parametrizado
--
-- Ningún objeto de este script obliga a tocar el modelo de la Entrega 1:
-- todo se apoya en HABITACION, TARIFA, DIM_TIEMPO, TEMPORADA, RESERVA,
-- RESERVA_HABITACION y PAGO tal como quedaron en el DDL original.
-- =====================================================================

SET ECHO ON

CREATE OR REPLACE PACKAGE pkg_turismo AS

   -- Colección de ids de habitación para una reserva de varias habitaciones.
   -- Se declara aquí (no como TYPE de esquema) porque el único llamador es
   -- PL/SQL: no hace falta el privilegio CREATE TYPE ni un objeto SQL aparte.
   TYPE t_lista_habitaciones IS TABLE OF habitacion.id_habitacion%TYPE
      INDEX BY PLS_INTEGER;

   -- ------------------------------------------------------------------
   -- fn_valor_estadia: valor de UNA habitación entre [p_fecha_in, p_fecha_out).
   -- Aplica la tarifa de CADA temporada que la estadía atraviese, sumando
   -- noche por noche. Es exactamente el MERGE del bloque D de
   -- 06_carga_masiva.sql, encapsulado como función reutilizable.
   -- ------------------------------------------------------------------
   FUNCTION fn_valor_estadia(
      p_id_habitacion IN habitacion.id_habitacion%TYPE,
      p_fecha_in      IN DATE,
      p_fecha_out     IN DATE
   ) RETURN NUMBER;

   -- ------------------------------------------------------------------
   -- sp_crear_reserva: crea la cabecera RESERVA y sus líneas
   -- RESERVA_HABITACION para una o varias habitaciones.
   -- Excepciones propias (RAISE_APPLICATION_ERROR):
   --   -20001  checkout <= checkin
   --   -20002  habitación no disponible (no existe, es de otro alojamiento,
   --           o se solapa con una reserva activa) -- misma regla de
   --           negocio que hace cumplir el disparador de fila anti-solape;
   --           aquí se valida primero para dar un mensaje claro al usuario.
   --   -20003  capacidad excedida (huéspedes > suma de capacidades)
   --   -20004  no se indicó ninguna habitación
   -- No hace COMMIT: la Entrega 3 la compone dentro de una transacción
   -- reserva+pago con su propio control de SAVEPOINT/COMMIT.
   -- ------------------------------------------------------------------
   PROCEDURE sp_crear_reserva(
      p_id_cliente     IN  cliente.id_cliente%TYPE,
      p_id_alojamiento IN  alojamiento.id_alojamiento%TYPE,
      p_fecha_checkin  IN  DATE,
      p_fecha_checkout IN  DATE,
      p_num_huespedes  IN  reserva.num_huespedes%TYPE,
      p_habitaciones   IN  t_lista_habitaciones,
      p_id_reserva     OUT reserva.id_reserva%TYPE,
      p_canal          IN  reserva.canal%TYPE DEFAULT 'WEB'
   );

   -- ------------------------------------------------------------------
   -- sp_liquidar_mes: proceso masivo de liquidación mensual por alojamiento.
   -- Recorre con un cursor explícito parametrizado (p_aloj, p_anio, p_mes)
   -- todas las reservas cuyo checkout cae en ese mes, y concilia valor
   -- facturado contra pagos aprobados. Solo imprime (DBMS_OUTPUT); no crea
   -- tabla nueva, siguiendo la decisión de no tocar el modelo.
   -- ------------------------------------------------------------------
   PROCEDURE sp_liquidar_mes(
      p_id_alojamiento IN alojamiento.id_alojamiento%TYPE,
      p_anio           IN PLS_INTEGER,
      p_mes            IN PLS_INTEGER
   );

END pkg_turismo;
/

CREATE OR REPLACE PACKAGE BODY pkg_turismo AS

   -- ==================================================================
   FUNCTION fn_valor_estadia(
      p_id_habitacion IN habitacion.id_habitacion%TYPE,
      p_fecha_in      IN DATE,
      p_fecha_out     IN DATE
   ) RETURN NUMBER IS
      v_valor        NUMBER := 0;
      v_noches_tarif PLS_INTEGER := 0;
      v_noches_estad PLS_INTEGER;
   BEGIN
      IF p_fecha_out <= p_fecha_in THEN
         RAISE_APPLICATION_ERROR(-20001,
            'fn_valor_estadia: la fecha de salida debe ser posterior a la de entrada.');
      END IF;

      v_noches_estad := p_fecha_out - p_fecha_in;

      -- Une cada noche de la estadía (DIM_TIEMPO) con la tarifa vigente en
      -- SU temporada para esta habitación (alojamiento + categoría). Si la
      -- estadía cruza dos o tres temporadas, cada tramo aporta su propia
      -- tarifa: no hay una sola tarifa "de la reserva".
      SELECT NVL(SUM(t.valor_noche), 0), COUNT(*)
        INTO v_valor, v_noches_tarif
        FROM habitacion h
        JOIN dim_tiempo  d ON d.fecha >= p_fecha_in AND d.fecha < p_fecha_out
        JOIN tarifa      t ON t.id_alojamiento = h.id_alojamiento
                           AND t.categoria      = h.categoria
                           AND t.id_temporada   = d.id_temporada
       WHERE h.id_habitacion = p_id_habitacion;

      -- Si el número de noches tarifadas no coincide con las noches de la
      -- estadía, algo falta: la habitación no existe, o hay una noche fuera
      -- del calendario cargado en DIM_TIEMPO, o sin tarifa para esa
      -- categoría/temporada. Sin este control el JOIN simplemente
      -- descartaría esa noche y la estadía saldría más barata sin ningún
      -- aviso: el peor tipo de error, silencioso.
      IF v_noches_tarif <> v_noches_estad THEN
         RAISE_APPLICATION_ERROR(-20005,
            'fn_valor_estadia: solo se encontró tarifa para ' || v_noches_tarif ||
            ' de las ' || v_noches_estad || ' noches solicitadas (habitación ' ||
            p_id_habitacion || '). Revise que la habitación exista y que ' ||
            'DIM_TIEMPO/TARIFA cubran ese rango de fechas.');
      END IF;

      RETURN v_valor;
   END fn_valor_estadia;

   -- ==================================================================
   PROCEDURE sp_crear_reserva(
      p_id_cliente     IN  cliente.id_cliente%TYPE,
      p_id_alojamiento IN  alojamiento.id_alojamiento%TYPE,
      p_fecha_checkin  IN  DATE,
      p_fecha_checkout IN  DATE,
      p_num_huespedes  IN  reserva.num_huespedes%TYPE,
      p_habitaciones   IN  t_lista_habitaciones,
      p_id_reserva     OUT reserva.id_reserva%TYPE,
      p_canal          IN  reserva.canal%TYPE DEFAULT 'WEB'
   ) IS
      v_id_alojam_hab   habitacion.id_alojamiento%TYPE;
      v_activa          habitacion.activa%TYPE;
      v_capacidad       habitacion.capacidad%TYPE;
      v_capacidad_total NUMBER := 0;
      v_solapadas       PLS_INTEGER;
      v_valor_hab       NUMBER;
      v_idx             PLS_INTEGER;
   BEGIN
      -- -20001 · checkout <= checkin
      IF p_fecha_checkout <= p_fecha_checkin THEN
         RAISE_APPLICATION_ERROR(-20001,
            'sp_crear_reserva: la fecha de checkout debe ser posterior a la de checkin.');
      END IF;

      -- -20004 · lista vacía
      IF p_habitaciones.COUNT = 0 THEN
         RAISE_APPLICATION_ERROR(-20004,
            'sp_crear_reserva: debe indicar al menos una habitación.');
      END IF;

      -- -20002 / -20003 · se valida CADA habitación antes de insertar nada
      v_idx := p_habitaciones.FIRST;
      WHILE v_idx IS NOT NULL LOOP

         BEGIN
            SELECT id_alojamiento, activa, capacidad
              INTO v_id_alojam_hab, v_activa, v_capacidad
              FROM habitacion
             WHERE id_habitacion = p_habitaciones(v_idx);
         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               RAISE_APPLICATION_ERROR(-20002,
                  'sp_crear_reserva: la habitación ' || p_habitaciones(v_idx) ||
                  ' no existe.');
         END;

         IF v_activa = 'N' THEN
            RAISE_APPLICATION_ERROR(-20002,
               'sp_crear_reserva: la habitación ' || p_habitaciones(v_idx) ||
               ' está inactiva.');
         END IF;

         IF v_id_alojam_hab <> p_id_alojamiento THEN
            RAISE_APPLICATION_ERROR(-20002,
               'sp_crear_reserva: la habitación ' || p_habitaciones(v_idx) ||
               ' no pertenece al alojamiento ' || p_id_alojamiento || '.');
         END IF;

         -- Misma condición de solapamiento que hará cumplir el disparador
         -- de fila trg_rh_anti_solape sobre RESERVA_HABITACION; se repite
         -- aquí para poder devolver un mensaje de negocio claro ANTES de
         -- intentar el INSERT.
         SELECT COUNT(*) INTO v_solapadas
           FROM reserva_habitacion rh
           JOIN reserva r ON r.id_reserva = rh.id_reserva
          WHERE rh.id_habitacion  = p_habitaciones(v_idx)
            AND r.estado         <> 'CANCELADA'
            AND r.fecha_checkin  < p_fecha_checkout
            AND p_fecha_checkin  < r.fecha_checkout;

         IF v_solapadas > 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
               'sp_crear_reserva: la habitación ' || p_habitaciones(v_idx) ||
               ' no está disponible entre ' || TO_CHAR(p_fecha_checkin, 'YYYY-MM-DD') ||
               ' y ' || TO_CHAR(p_fecha_checkout, 'YYYY-MM-DD') || '.');
         END IF;

         v_capacidad_total := v_capacidad_total + v_capacidad;
         v_idx := p_habitaciones.NEXT(v_idx);
      END LOOP;

      -- -20003 · capacidad excedida
      IF p_num_huespedes > v_capacidad_total THEN
         RAISE_APPLICATION_ERROR(-20003,
            'sp_crear_reserva: la capacidad de las habitaciones seleccionadas (' ||
            v_capacidad_total || ') es menor a los ' || p_num_huespedes || ' huéspedes.');
      END IF;

      -- Cabecera. El id se pide ANTES del INSERT (y no con RETURNING) porque
      -- se necesita para las líneas hijas de RESERVA_HABITACION que siguen.
      p_id_reserva := seq_reserva.NEXTVAL;

      INSERT INTO reserva (id_reserva, id_cliente, id_alojamiento, fecha_reserva,
                           fecha_checkin, fecha_checkout, num_huespedes,
                           estado, canal, valor_alojamiento, valor_servicios)
      VALUES (p_id_reserva, p_id_cliente, p_id_alojamiento, TRUNC(SYSDATE),
              p_fecha_checkin, p_fecha_checkout, p_num_huespedes,
              'CONFIRMADA', p_canal, 0, 0);

      -- Líneas de habitación, cada una con su valor calculado por
      -- fn_valor_estadia (así la función y el procedimiento quedan
      -- integrados, no duplicando la lógica de tarifas).
      v_idx := p_habitaciones.FIRST;
      WHILE v_idx IS NOT NULL LOOP
         v_valor_hab := fn_valor_estadia(p_habitaciones(v_idx), p_fecha_checkin, p_fecha_checkout);

         INSERT INTO reserva_habitacion (id_reserva, id_habitacion, huespedes, valor_noches)
         VALUES (p_id_reserva, p_habitaciones(v_idx), 1, v_valor_hab);

         v_idx := p_habitaciones.NEXT(v_idx);
      END LOOP;

      -- Cabecera = suma de sus líneas (misma regla que 09_validacion.sql
      -- comprueba en el bloque 6 "Cabecera <> suma de habitaciones").
      UPDATE reserva
         SET valor_alojamiento = (SELECT NVL(SUM(valor_noches), 0)
                                    FROM reserva_habitacion
                                   WHERE id_reserva = p_id_reserva)
       WHERE id_reserva = p_id_reserva;

      -- Sin COMMIT a propósito (ver comentario en la especificación).
   END sp_crear_reserva;

   -- ==================================================================
   PROCEDURE sp_liquidar_mes(
      p_id_alojamiento IN alojamiento.id_alojamiento%TYPE,
      p_anio           IN PLS_INTEGER,
      p_mes            IN PLS_INTEGER
   ) IS
      -- Cursor explícito CON PARÁMETROS: la liquidación de un alojamiento
      -- se factura sobre las estadías que TERMINARON (checkout) ese mes.
      CURSOR c_liq(p_aloj IN NUMBER, p_anio IN NUMBER, p_mes IN NUMBER) IS
         SELECT r.id_reserva, r.fecha_checkin, r.fecha_checkout,
                r.valor_alojamiento, r.valor_servicios, r.valor_total
           FROM reserva r
          WHERE r.id_alojamiento = p_aloj
            AND r.estado IN ('CONFIRMADA', 'COMPLETADA')
            AND EXTRACT(YEAR  FROM r.fecha_checkout) = p_anio
            AND EXTRACT(MONTH FROM r.fecha_checkout) = p_mes
          ORDER BY r.fecha_checkout;

      v_reserva      c_liq%ROWTYPE;
      v_pagado       NUMBER;
      v_tot_reservas PLS_INTEGER := 0;
      v_tot_valor    NUMBER := 0;
      v_tot_pagado   NUMBER := 0;
   BEGIN
      DBMS_OUTPUT.PUT_LINE('=== Liquidación · alojamiento ' || p_id_alojamiento ||
                            ' · ' || LPAD(p_mes, 2, '0') || '/' || p_anio || ' ===');

      OPEN c_liq(p_id_alojamiento, p_anio, p_mes);
      LOOP
         FETCH c_liq INTO v_reserva;
         EXIT WHEN c_liq%NOTFOUND;

         SELECT NVL(SUM(pg.valor), 0) INTO v_pagado
           FROM pago pg
          WHERE pg.id_reserva = v_reserva.id_reserva
            AND pg.estado     = 'APROBADO';

         DBMS_OUTPUT.PUT_LINE('  reserva ' || v_reserva.id_reserva ||
            ' | checkout ' || TO_CHAR(v_reserva.fecha_checkout, 'YYYY-MM-DD') ||
            ' | total ' || v_reserva.valor_total ||
            ' | pagado ' || v_pagado ||
            ' | saldo ' || (v_reserva.valor_total - v_pagado));

         v_tot_reservas := v_tot_reservas + 1;
         v_tot_valor    := v_tot_valor  + v_reserva.valor_total;
         v_tot_pagado   := v_tot_pagado + v_pagado;
      END LOOP;
      CLOSE c_liq;

      DBMS_OUTPUT.PUT_LINE('--- Total: ' || v_tot_reservas || ' reservas · facturado ' ||
         v_tot_valor || ' · pagado ' || v_tot_pagado || ' · saldo pendiente ' ||
         (v_tot_valor - v_tot_pagado));
   END sp_liquidar_mes;

END pkg_turismo;
/

PROMPT === Estado de PKG_TURISMO ===
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name = 'PKG_TURISMO';

-- Si algo queda INVALID, ver el detalle con:
-- SELECT line, position, text FROM user_errors WHERE name = 'PKG_TURISMO' ORDER BY sequence;
SHOW ERRORS PACKAGE BODY pkg_turismo
