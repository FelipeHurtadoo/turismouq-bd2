-- =====================================================================
-- TurismoUQ · 14_pkg_transacciones.sql
-- Ejecutar como: TURISMO_UQ
-- Oracle XE 21c
--
-- Entrega 3 · Transacciones y concurrencia. Paquete PKG_TRANSACCIONES:
--   · sp_buscar_hueco          : utilidad para los guiones de demostración
--   · sp_crear_reserva_segura  : sp_crear_reserva + SELECT ... FOR UPDATE
--                                sobre HABITACION (control de concurrencia)
--   · sp_reservar_y_pagar      : reserva + pago ATÓMICOS, con SAVEPOINT y
--                                rollback parcial si el pago falla
--   · sp_registrar_pago        : pagar después (o abonar) una reserva que
--                                quedó PENDIENTE, también con SAVEPOINT
--
-- Pasarela de pagos: la interfaz web (app/pasarela.py) simula la pasarela
-- y le pasa a estos procedimientos su RESPUESTA ('APROBADO' / 'RECHAZADO')
-- y su número de transacción. La decisión de qué se confirma y qué se
-- deshace sigue viviendo aquí, dentro de la transacción de la base.
--
-- No reemplaza a PKG_TURISMO (Entrega 2): lo COMPONE. La lógica de
-- disponibilidad, capacidad y tarifas sigue viviendo en un solo lugar
-- (pkg_turismo.sp_crear_reserva / fn_valor_estadia). Este paquete solo
-- agrega lo que la Entrega 3 exige: límites de transacción y bloqueo.
--
-- Ningún objeto de este script modifica tablas de la Entrega 1.
-- =====================================================================

SET ECHO ON

CREATE OR REPLACE PACKAGE pkg_transacciones AS

   -- Marca que llevan las reservas creadas por los guiones de demostración
   -- (15, 16). Permite limpiarlas al re-ejecutar sin tocar el histórico.
   c_marca_demo CONSTANT VARCHAR2(20) := 'DEMO_E3';

   -- Alias del tipo colección de PKG_TURISMO. Existe por SEGURIDAD: el rol
   -- de recepción recibe EXECUTE sobre este paquete y NO sobre PKG_TURISMO
   -- (que le permitiría llamar sp_crear_reserva sin el control de ámbito).
   -- Para declarar la lista de habitaciones necesita un tipo visible aquí.
   -- Es el mismo tipo base, así que se pasa sin conversión a PKG_TURISMO.
   SUBTYPE t_lista_habitaciones IS pkg_turismo.t_lista_habitaciones;

   -- ------------------------------------------------------------------
   -- sp_buscar_hueco: primera habitación activa libre durante p_noches
   -- noches a partir de mañana (orden determinista: fecha, habitación).
   -- Solo existe para que los guiones de prueba no dependan de ids fijos.
   -- p_excluir_hab: permite pedir "otra habitación distinta a esta".
   -- p_solo_aloj  : limita la búsqueda a un alojamiento (pruebas de ámbito).
   -- ------------------------------------------------------------------
   PROCEDURE sp_buscar_hueco(
      p_noches         IN  PLS_INTEGER,
      p_id_habitacion  OUT habitacion.id_habitacion%TYPE,
      p_id_alojamiento OUT alojamiento.id_alojamiento%TYPE,
      p_fecha_in       OUT DATE,
      p_excluir_hab    IN  habitacion.id_habitacion%TYPE DEFAULT NULL,
      p_solo_aloj      IN  alojamiento.id_alojamiento%TYPE DEFAULT NULL
   );

   -- ------------------------------------------------------------------
   -- sp_crear_reserva_segura: igual que pkg_turismo.sp_crear_reserva,
   -- pero ANTES de validar disponibilidad bloquea con SELECT ... FOR UPDATE
   -- la fila de cada HABITACION pedida. Dos sesiones que compitan por la
   -- misma habitación quedan serializadas: la segunda espera el COMMIT de
   -- la primera y, al continuar, ve su reserva ya confirmada (-20002).
   --
   -- p_espera_seg controla cuánto se espera por el bloqueo:
   --   NULL -> FOR UPDATE           (espera indefinida)
   --   0    -> FOR UPDATE NOWAIT    (falla de inmediato)
   --   n    -> FOR UPDATE WAIT n    (espera hasta n segundos)
   -- Si no consigue el bloqueo a tiempo: -20006.
   --
   -- No hace COMMIT: el bloqueo se libera con el COMMIT/ROLLBACK de quien
   -- llama, que es justamente lo que mantiene la habitación "apartada"
   -- mientras dura la transacción.
   -- ------------------------------------------------------------------
   PROCEDURE sp_crear_reserva_segura(
      p_id_cliente     IN  cliente.id_cliente%TYPE,
      p_id_alojamiento IN  alojamiento.id_alojamiento%TYPE,
      p_fecha_checkin  IN  DATE,
      p_fecha_checkout IN  DATE,
      p_num_huespedes  IN  reserva.num_huespedes%TYPE,
      p_habitaciones   IN  t_lista_habitaciones,
      p_id_reserva     OUT reserva.id_reserva%TYPE,
      p_canal          IN  reserva.canal%TYPE DEFAULT 'WEB',
      p_espera_seg     IN  PLS_INTEGER DEFAULT NULL
   );

   -- ------------------------------------------------------------------
   -- sp_reservar_y_pagar: registra reserva + pago en UNA transacción.
   --
   --   SAVEPOINT sp_inicio
   --     reserva (sp_crear_reserva_segura)   -- si falla: ROLLBACK TO
   --   SAVEPOINT sp_antes_pago                  sp_inicio y RAISE (nada
   --     pago                                   queda grabado)
   --       -- si falla: ROLLBACK TO sp_antes_pago  (rollback PARCIAL):
   --       -- se deshace SOLO el pago; la reserva se conserva en estado
   --       -- PENDIENTE para que el cliente pague después.
   --   COMMIT
   --
   -- Resultado en p_resultado: 'PAGADA' o 'PENDIENTE_PAGO'.
   -- p_commit = FALSE deja la transacción abierta (para los guiones que
   -- quieren mostrar estados intermedios o el bloqueo en vivo).
   --
   -- Excepciones propias del pago (se capturan y producen el rollback
   -- parcial, no se propagan):
   --   -20010  valor de pago <= 0
   --   -20011  valor de pago mayor al total de la reserva
   --   -20012  la pasarela de pagos rechazó la transacción
   -- Cualquier otro error del INSERT en PAGO (medio de pago inválido,
   -- referencia duplicada...) también produce el rollback parcial.
   --
   -- Pasarela: p_respuesta_pasarela es lo que respondió la pasarela
   -- ('APROBADO' por defecto, para los llamadores que no usan pasarela) y
   -- p_referencia su número de transacción, que queda en PAGO.REFERENCIA.
   -- ------------------------------------------------------------------
   PROCEDURE sp_reservar_y_pagar(
      p_id_cliente     IN  cliente.id_cliente%TYPE,
      p_id_alojamiento IN  alojamiento.id_alojamiento%TYPE,
      p_fecha_checkin  IN  DATE,
      p_fecha_checkout IN  DATE,
      p_num_huespedes  IN  reserva.num_huespedes%TYPE,
      p_habitaciones   IN  t_lista_habitaciones,
      p_valor_pago     IN  pago.valor%TYPE,
      p_medio_pago     IN  pago.medio_pago%TYPE,
      p_id_reserva     OUT reserva.id_reserva%TYPE,
      p_resultado      OUT VARCHAR2,
      p_canal          IN  reserva.canal%TYPE DEFAULT 'WEB',
      p_observaciones  IN  reserva.observaciones%TYPE DEFAULT NULL,
      p_espera_seg     IN  PLS_INTEGER DEFAULT NULL,
      p_commit         IN  BOOLEAN DEFAULT TRUE,
      p_respuesta_pasarela IN VARCHAR2 DEFAULT 'APROBADO',
      p_referencia     IN  pago.referencia%TYPE DEFAULT NULL,
      p_detalle_pasarela IN VARCHAR2 DEFAULT NULL
   );

   -- ------------------------------------------------------------------
   -- sp_registrar_pago: registra un pago (total o abono) sobre una reserva
   -- que ya existe; el caso típico es la reserva que quedó PENDIENTE porque
   -- su primer pago fue rechazado.
   --
   --   SELECT ... FOR UPDATE sobre la RESERVA   (dos cajeros no pueden
   --                                             cobrar el mismo saldo a la vez)
   --   SAVEPOINT sp_pago
   --     valida estado y saldo, consulta la respuesta de la pasarela,
   --     INSERT INTO pago, y si el saldo llega a 0 -> CONFIRMADA
   --   si algo falla -> ROLLBACK TO sp_pago: la reserva queda como estaba
   --   COMMIT (salvo p_commit => FALSE)
   --
   -- p_resultado: 'PAGADA' (saldo en 0), 'ABONO' (queda saldo) o
   -- 'RECHAZADO' (no se registró nada; el motivo va en p_mensaje).
   -- Errores de uso que SÍ se propagan: -20013 reserva inexistente o
   -- cancelada, -20020 alojamiento ajeno (ámbito del usuario).
   -- ------------------------------------------------------------------
   PROCEDURE sp_registrar_pago(
      p_id_reserva     IN  reserva.id_reserva%TYPE,
      p_valor_pago     IN  pago.valor%TYPE,
      p_medio_pago     IN  pago.medio_pago%TYPE,
      p_resultado      OUT VARCHAR2,
      p_mensaje        OUT VARCHAR2,
      p_respuesta_pasarela IN VARCHAR2 DEFAULT 'APROBADO',
      p_referencia     IN  pago.referencia%TYPE DEFAULT NULL,
      p_detalle_pasarela IN VARCHAR2 DEFAULT NULL,
      p_commit         IN  BOOLEAN DEFAULT TRUE
   );

END pkg_transacciones;
/

CREATE OR REPLACE PACKAGE BODY pkg_transacciones AS

   -- ==================================================================
   -- Ámbito: si quien llama es un usuario de BD que corresponde a un
   -- USUARIO_SISTEMA de recepción o de administración de alojamiento, solo
   -- puede operar sobre SU alojamiento. El esquema dueño y los roles
   -- transversales (gerente, auditor) no tienen fila con alojamiento.
   -- ==================================================================
   PROCEDURE verificar_ambito(p_id_alojamiento IN NUMBER) IS
      v_aloj_usuario usuario_sistema.id_alojamiento%TYPE;
   BEGIN
      SELECT MAX(id_alojamiento) INTO v_aloj_usuario
        FROM usuario_sistema
       WHERE UPPER(username) = SYS_CONTEXT('USERENV', 'SESSION_USER')
         AND activo = 'S';

      IF v_aloj_usuario IS NOT NULL AND v_aloj_usuario <> p_id_alojamiento THEN
         RAISE_APPLICATION_ERROR(-20020,
            'El usuario ' || SYS_CONTEXT('USERENV', 'SESSION_USER') ||
            ' solo puede operar sobre el alojamiento ' || v_aloj_usuario || '.');
      END IF;
   END verificar_ambito;

   -- ==================================================================
   PROCEDURE sp_buscar_hueco(
      p_noches         IN  PLS_INTEGER,
      p_id_habitacion  OUT habitacion.id_habitacion%TYPE,
      p_id_alojamiento OUT alojamiento.id_alojamiento%TYPE,
      p_fecha_in       OUT DATE,
      p_excluir_hab    IN  habitacion.id_habitacion%TYPE DEFAULT NULL,
      p_solo_aloj      IN  alojamiento.id_alojamiento%TYPE DEFAULT NULL
   ) IS
      -- Desde mañana: CK_RESERVA_ANTICIP exige fecha_reserva <= checkin y
      -- sp_crear_reserva graba fecha_reserva = hoy. Hasta donde llegue
      -- DIM_TIEMPO, porque fn_valor_estadia necesita tarifa para cada noche.
      v_desde DATE := TRUNC(SYSDATE) + 1;
      v_hasta DATE;
   BEGIN
      SELECT MAX(fecha) + 1 INTO v_hasta FROM dim_tiempo;

      -- El primer hueco libre de una habitación SIEMPRE empieza o "mañana"
      -- o el día de un checkout (si empezara en otro día, se podría correr
      -- hacia atrás hasta el checkout anterior sin chocar con nada). Por eso
      -- solo se evalúan esos candidatos: unos cientos, en lugar de
      -- habitaciones x días (~25.000 combinaciones con un NOT EXISTS cada
      -- una, que superaba el LOGICAL_READS_PER_CALL del perfil de recepción).
      WITH ocupacion AS (
         SELECT rh.id_habitacion, r.fecha_checkin, r.fecha_checkout
           FROM reserva_habitacion rh
           JOIN reserva r ON r.id_reserva = rh.id_reserva
          WHERE r.estado        <> 'CANCELADA'
            AND r.fecha_checkout > v_desde
      ),
      habitaciones AS (
         SELECT h.id_habitacion, h.id_alojamiento
           FROM habitacion  h
           JOIN alojamiento a ON a.id_alojamiento = h.id_alojamiento
          WHERE h.activa = 'S'
            AND a.activo = 'S'
            AND (p_excluir_hab IS NULL OR h.id_habitacion <> p_excluir_hab)
            AND (p_solo_aloj   IS NULL OR h.id_alojamiento = p_solo_aloj)
      ),
      candidatos AS (
         SELECT hb.id_habitacion, hb.id_alojamiento, v_desde AS fecha
           FROM habitaciones hb
         UNION
         SELECT hb.id_habitacion, hb.id_alojamiento, o.fecha_checkout
           FROM habitaciones hb
           JOIN ocupacion o ON o.id_habitacion = hb.id_habitacion
      )
      SELECT id_habitacion, id_alojamiento, fecha
        INTO p_id_habitacion, p_id_alojamiento, p_fecha_in
        FROM (
           SELECT c.id_habitacion, c.id_alojamiento, c.fecha
             FROM candidatos c
            WHERE c.fecha + p_noches <= v_hasta
              AND NOT EXISTS (
                     SELECT 1 FROM ocupacion o
                      WHERE o.id_habitacion  = c.id_habitacion
                        AND o.fecha_checkin  < c.fecha + p_noches
                        AND c.fecha          < o.fecha_checkout)
            ORDER BY c.fecha, c.id_habitacion
        )
       WHERE ROWNUM = 1;
   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RAISE_APPLICATION_ERROR(-20009,
            'sp_buscar_hueco: no hay ninguna habitación libre ' || p_noches ||
            ' noches entre mañana y el fin del calendario cargado en DIM_TIEMPO.');
   END sp_buscar_hueco;

   -- ==================================================================
   PROCEDURE sp_crear_reserva_segura(
      p_id_cliente     IN  cliente.id_cliente%TYPE,
      p_id_alojamiento IN  alojamiento.id_alojamiento%TYPE,
      p_fecha_checkin  IN  DATE,
      p_fecha_checkout IN  DATE,
      p_num_huespedes  IN  reserva.num_huespedes%TYPE,
      p_habitaciones   IN  t_lista_habitaciones,
      p_id_reserva     OUT reserva.id_reserva%TYPE,
      p_canal          IN  reserva.canal%TYPE DEFAULT 'WEB',
      p_espera_seg     IN  PLS_INTEGER DEFAULT NULL
   ) IS
      e_recurso_ocupado EXCEPTION;   -- ORA-00054: NOWAIT y la fila está tomada
      e_espera_agotada  EXCEPTION;   -- ORA-30006: se agotó el WAIT n
      PRAGMA EXCEPTION_INIT(e_recurso_ocupado, -54);
      PRAGMA EXCEPTION_INIT(e_espera_agotada, -30006);

      TYPE t_ids IS TABLE OF NUMBER;
      v_ids   t_ids := t_ids();
      v_tmp   NUMBER;
      v_idx   PLS_INTEGER;
      v_sql   VARCHAR2(200);
      v_lock  NUMBER;
   BEGIN
      verificar_ambito(p_id_alojamiento);

      -- Copia ordenada de los ids. Bloquear SIEMPRE en el mismo orden
      -- (ascendente) evita el interbloqueo clásico: A toma 10 y pide 11
      -- mientras B toma 11 y pide 10 (ORA-00060).
      v_idx := p_habitaciones.FIRST;
      WHILE v_idx IS NOT NULL LOOP
         v_ids.EXTEND;
         v_ids(v_ids.LAST) := p_habitaciones(v_idx);
         v_idx := p_habitaciones.NEXT(v_idx);
      END LOOP;

      FOR i IN 2 .. v_ids.COUNT LOOP           -- inserción: listas de 1 a 4
         v_tmp := v_ids(i);
         v_idx := i - 1;
         WHILE v_idx >= 1 AND v_ids(v_idx) > v_tmp LOOP
            v_ids(v_idx + 1) := v_ids(v_idx);
            v_idx := v_idx - 1;
         END LOOP;
         v_ids(v_idx + 1) := v_tmp;
      END LOOP;

      -- El bloqueo. HABITACION es el recurso escaso: al bloquear su fila, la
      -- segunda transacción que la pida se detiene AQUÍ, antes de leer la
      -- disponibilidad. Cuando continúa, la consulta de disponibilidad de
      -- sp_crear_reserva es una sentencia NUEVA y por lo tanto ya ve lo que
      -- la primera confirmó (lectura consistente a nivel de sentencia).
      -- WAIT n no admite variable de enlace: por eso SQL dinámico.
      v_sql := 'SELECT id_habitacion FROM habitacion WHERE id_habitacion = :1 FOR UPDATE' ||
               CASE WHEN p_espera_seg IS NULL THEN NULL
                    WHEN p_espera_seg = 0     THEN ' NOWAIT'
                    ELSE ' WAIT ' || TO_CHAR(TRUNC(p_espera_seg)) END;

      FOR i IN 1 .. v_ids.COUNT LOOP
         BEGIN
            EXECUTE IMMEDIATE v_sql INTO v_lock USING v_ids(i);
         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               NULL;   -- no existe: sp_crear_reserva lanza el -20002 con su mensaje
            WHEN e_recurso_ocupado OR e_espera_agotada THEN
               RAISE_APPLICATION_ERROR(-20006,
                  'sp_crear_reserva_segura: la habitación ' || v_ids(i) ||
                  ' está siendo reservada por otra transacción en este momento ' ||
                  '(' || SQLERRM || '). Intente de nuevo.');
         END;
      END LOOP;

      pkg_turismo.sp_crear_reserva(
         p_id_cliente     => p_id_cliente,
         p_id_alojamiento => p_id_alojamiento,
         p_fecha_checkin  => p_fecha_checkin,
         p_fecha_checkout => p_fecha_checkout,
         p_num_huespedes  => p_num_huespedes,
         p_habitaciones   => p_habitaciones,
         p_id_reserva     => p_id_reserva,
         p_canal          => p_canal);
   END sp_crear_reserva_segura;

   -- ==================================================================
   PROCEDURE sp_reservar_y_pagar(
      p_id_cliente     IN  cliente.id_cliente%TYPE,
      p_id_alojamiento IN  alojamiento.id_alojamiento%TYPE,
      p_fecha_checkin  IN  DATE,
      p_fecha_checkout IN  DATE,
      p_num_huespedes  IN  reserva.num_huespedes%TYPE,
      p_habitaciones   IN  t_lista_habitaciones,
      p_valor_pago     IN  pago.valor%TYPE,
      p_medio_pago     IN  pago.medio_pago%TYPE,
      p_id_reserva     OUT reserva.id_reserva%TYPE,
      p_resultado      OUT VARCHAR2,
      p_canal          IN  reserva.canal%TYPE DEFAULT 'WEB',
      p_observaciones  IN  reserva.observaciones%TYPE DEFAULT NULL,
      p_espera_seg     IN  PLS_INTEGER DEFAULT NULL,
      p_commit         IN  BOOLEAN DEFAULT TRUE,
      p_respuesta_pasarela IN VARCHAR2 DEFAULT 'APROBADO',
      p_referencia     IN  pago.referencia%TYPE DEFAULT NULL,
      p_detalle_pasarela IN VARCHAR2 DEFAULT NULL
   ) IS
      v_total   reserva.valor_total%TYPE;
      v_id_pago pago.id_pago%TYPE;
      v_motivo  VARCHAR2(300);
   BEGIN
      -- ---------------- Fase 1: la reserva ----------------
      SAVEPOINT sp_inicio;
      BEGIN
         sp_crear_reserva_segura(
            p_id_cliente     => p_id_cliente,
            p_id_alojamiento => p_id_alojamiento,
            p_fecha_checkin  => p_fecha_checkin,
            p_fecha_checkout => p_fecha_checkout,
            p_num_huespedes  => p_num_huespedes,
            p_habitaciones   => p_habitaciones,
            p_id_reserva     => p_id_reserva,
            p_canal          => p_canal,
            p_espera_seg     => p_espera_seg);
      EXCEPTION
         WHEN OTHERS THEN
            -- Rollback TOTAL de lo que hizo este procedimiento (no de lo que
            -- el llamador tuviera antes del SAVEPOINT) y se propaga el error.
            ROLLBACK TO SAVEPOINT sp_inicio;
            RAISE;
      END;

      IF p_observaciones IS NOT NULL THEN
         UPDATE reserva SET observaciones = p_observaciones
          WHERE id_reserva = p_id_reserva;
      END IF;

      -- ---------------- Fase 2: el pago ----------------
      SAVEPOINT sp_antes_pago;
      BEGIN
         SELECT valor_total INTO v_total FROM reserva WHERE id_reserva = p_id_reserva;

         IF p_valor_pago IS NULL OR p_valor_pago <= 0 THEN
            RAISE_APPLICATION_ERROR(-20010,
               'sp_reservar_y_pagar: el valor del pago debe ser mayor que cero.');
         END IF;

         IF p_valor_pago > v_total THEN
            RAISE_APPLICATION_ERROR(-20011,
               'sp_reservar_y_pagar: el pago (' || p_valor_pago ||
               ') supera el total de la reserva (' || v_total || ').');
         END IF;

         -- La pasarela respondió que no (fondos insuficientes, tarjeta
         -- bloqueada...): es exactamente el caso del rollback parcial.
         IF NVL(p_respuesta_pasarela, 'RECHAZADO') <> 'APROBADO' THEN
            RAISE_APPLICATION_ERROR(-20012,
               'Pasarela: pago rechazado' ||
               NVL2(p_detalle_pasarela, ' (' || p_detalle_pasarela || ')', '') ||
               NVL2(p_referencia, ' · transacción ' || p_referencia, '') || '.');
         END IF;

         -- El pago entra primero como fila, y DESPUÉS la reserva pasa a
         -- CONFIRMADA. Si cualquiera de los dos pasos falla, el ROLLBACK TO
         -- de abajo deshace ambos y deja la reserva exactamente como estaba
         -- al terminar la fase 1.
         v_id_pago := seq_pago.NEXTVAL;
         INSERT INTO pago (id_pago, id_reserva, fecha_pago, valor, medio_pago,
                           estado, referencia)
         VALUES (v_id_pago, p_id_reserva, SYSDATE, p_valor_pago, p_medio_pago,
                 'APROBADO', NVL(p_referencia, 'TX-' || p_id_reserva || '-' || v_id_pago));

         UPDATE reserva SET estado = 'CONFIRMADA' WHERE id_reserva = p_id_reserva;

         p_resultado := 'PAGADA';
      EXCEPTION
         WHEN OTHERS THEN
            v_motivo := SUBSTR(SQLERRM, 1, 200);

            -- ROLLBACK PARCIAL: se deshace solo lo posterior al SAVEPOINT
            -- sp_antes_pago (el pago). La reserva y sus líneas de habitación
            -- siguen vivas en la transacción, y la habitación sigue bloqueada.
            ROLLBACK TO SAVEPOINT sp_antes_pago;

            UPDATE reserva
               SET estado        = 'PENDIENTE',
                   observaciones = SUBSTR(NVL(p_observaciones || ' | ', '') ||
                                          'Pago rechazado: ' || v_motivo, 1, 300)
             WHERE id_reserva = p_id_reserva;

            p_resultado := 'PENDIENTE_PAGO';
      END;

      IF p_commit THEN
         COMMIT;
      END IF;
   END sp_reservar_y_pagar;

   -- ==================================================================
   PROCEDURE sp_registrar_pago(
      p_id_reserva     IN  reserva.id_reserva%TYPE,
      p_valor_pago     IN  pago.valor%TYPE,
      p_medio_pago     IN  pago.medio_pago%TYPE,
      p_resultado      OUT VARCHAR2,
      p_mensaje        OUT VARCHAR2,
      p_respuesta_pasarela IN VARCHAR2 DEFAULT 'APROBADO',
      p_referencia     IN  pago.referencia%TYPE DEFAULT NULL,
      p_detalle_pasarela IN VARCHAR2 DEFAULT NULL,
      p_commit         IN  BOOLEAN DEFAULT TRUE
   ) IS
      v_aloj    reserva.id_alojamiento%TYPE;
      v_estado  reserva.estado%TYPE;
      v_total   reserva.valor_total%TYPE;
      v_pagado  NUMBER;
      v_saldo   NUMBER;
      v_id_pago pago.id_pago%TYPE;
   BEGIN
      -- Bloqueo de la reserva ANTES de calcular el saldo: si dos cajeros
      -- (o dos pestañas) cobran a la vez, el segundo espera y luego ve el
      -- pago del primero. Sin esto, ambos verían el mismo saldo y la
      -- reserva quedaría pagada dos veces: la misma carrera de la FASE 3.
      BEGIN
         SELECT id_alojamiento, estado, valor_total
           INTO v_aloj, v_estado, v_total
           FROM reserva
          WHERE id_reserva = p_id_reserva
            FOR UPDATE;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20013,
               'sp_registrar_pago: la reserva ' || p_id_reserva || ' no existe.');
      END;

      verificar_ambito(v_aloj);

      IF v_estado IN ('CANCELADA', 'NO_SHOW') THEN
         RAISE_APPLICATION_ERROR(-20013,
            'sp_registrar_pago: la reserva ' || p_id_reserva || ' está ' || v_estado ||
            ' y no admite pagos.');
      END IF;

      SAVEPOINT sp_pago;
      BEGIN
         SELECT NVL(SUM(valor), 0) INTO v_pagado
           FROM pago
          WHERE id_reserva = p_id_reserva AND estado = 'APROBADO';
         v_saldo := v_total - v_pagado;

         IF p_valor_pago IS NULL OR p_valor_pago <= 0 THEN
            RAISE_APPLICATION_ERROR(-20010,
               'el valor del pago debe ser mayor que cero.');
         END IF;
         IF p_valor_pago > v_saldo THEN
            RAISE_APPLICATION_ERROR(-20011,
               'el pago (' || p_valor_pago || ') supera el saldo pendiente (' || v_saldo || ').');
         END IF;
         IF NVL(p_respuesta_pasarela, 'RECHAZADO') <> 'APROBADO' THEN
            RAISE_APPLICATION_ERROR(-20012,
               'Pasarela: pago rechazado' ||
               NVL2(p_detalle_pasarela, ' (' || p_detalle_pasarela || ')', '') ||
               NVL2(p_referencia, ' · transacción ' || p_referencia, '') || '.');
         END IF;

         v_id_pago := seq_pago.NEXTVAL;
         INSERT INTO pago (id_pago, id_reserva, fecha_pago, valor, medio_pago,
                           estado, referencia)
         VALUES (v_id_pago, p_id_reserva, SYSDATE, p_valor_pago, p_medio_pago,
                 'APROBADO', NVL(p_referencia, 'TX-' || p_id_reserva || '-' || v_id_pago));

         IF p_valor_pago = v_saldo THEN
            UPDATE reserva SET estado = 'CONFIRMADA'
             WHERE id_reserva = p_id_reserva AND estado = 'PENDIENTE';
            p_resultado := 'PAGADA';
            p_mensaje   := 'Saldo cubierto. Reserva confirmada.';
         ELSE
            p_resultado := 'ABONO';
            p_mensaje   := 'Abono registrado. Saldo pendiente: ' || (v_saldo - p_valor_pago) || '.';
         END IF;
      EXCEPTION
         WHEN OTHERS THEN
            -- Nada del intento queda grabado; la reserva sigue igual.
            ROLLBACK TO SAVEPOINT sp_pago;
            p_resultado := 'RECHAZADO';
            p_mensaje   := SUBSTR(SQLERRM, 1, 300);
      END;

      IF p_commit THEN
         COMMIT;
      END IF;
   END sp_registrar_pago;

END pkg_transacciones;
/

PROMPT === Estado de PKG_TRANSACCIONES ===
SELECT object_name, object_type, status
  FROM user_objects
 WHERE object_name = 'PKG_TRANSACCIONES';

SHOW ERRORS PACKAGE BODY pkg_transacciones
