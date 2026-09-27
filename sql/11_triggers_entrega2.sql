-- =====================================================================
-- TurismoUQ · 11_triggers_entrega2.sql
-- Ejecutar como: TURISMO_UQ
-- Oracle XE 21c
--
-- Entrega 2 · Los dos disparadores exigidos por el documento:
--   1) trg_tarifa_auditoria   -> nivel de SENTENCIA, sobre TARIFA
--   2) trg_rh_anti_solape     -> nivel de FILA, sobre RESERVA_HABITACION
--
-- Ambos se implementan como COMPOUND TRIGGER. No es capricho de estilo:
-- es la única forma limpia de resolver lo que cada uno necesita sin caer
-- en ORA-04091 (tabla mutante) ni perder el detalle fila por fila.
-- =====================================================================

SET ECHO ON

-- =====================================================================
-- 1) DISPARADOR DE SENTENCIA · auditoría de cambios sobre TARIFA
-- =====================================================================
-- Requisito: "quién, cuándo, valor anterior y nuevo", y que sea un
-- disparador A NIVEL DE SENTENCIA (dispara una vez por INSERT/UPDATE/DELETE,
-- sin importar cuántas filas de TARIFA afecte esa sentencia).
--
-- El problema de fondo: un disparador de sentencia PURO (FOR ... , sin
-- FOR EACH ROW) no tiene acceso a :OLD/:NEW, porque esos valores son por
-- fila. La salida es un COMPOUND TRIGGER: la sección AFTER EACH ROW SÍ ve
-- :OLD/:NEW y va guardando el último valor tocado y cuántas filas van;
-- la sección AFTER STATEMENT hace UNA sola inserción en AUDITORIA_TARIFA
-- cuando la sentencia completa termina. El disparador sigue disparando
-- una sola vez por sentencia (eso es lo que lo hace "de sentencia": UNA
-- ejecución del bloque AFTER STATEMENT, no una por fila).
--
-- Decisión de diseño: en este proyecto una actualización de TARIFA es casi
-- siempre de una sola fila (el admin del alojamiento corrige un precio
-- puntual). Por eso valor_anterior/valor_nuevo son columnas escalares en
-- AUDITORIA_TARIFA (ya así desde el DDL de la Entrega 1) y no una fila por
-- cada registro tocado: si una sentencia llegara a afectar varias filas,
-- queda registrado el último valor tocado y el conteo real en
-- FILAS_AFECTADAS, que es precisamente para qué existe esa columna.
-- =====================================================================
CREATE OR REPLACE TRIGGER trg_tarifa_auditoria
   FOR INSERT OR UPDATE OR DELETE ON tarifa
   COMPOUND TRIGGER

   v_operacion VARCHAR2(10);
   v_filas     PLS_INTEGER := 0;
   v_id_tarifa tarifa.id_tarifa%TYPE;
   v_valor_ant tarifa.valor_noche%TYPE;
   v_valor_nue tarifa.valor_noche%TYPE;

   BEFORE STATEMENT IS
   BEGIN
      v_filas     := 0;
      v_id_tarifa := NULL;
      v_valor_ant := NULL;
      v_valor_nue := NULL;
      v_operacion := CASE WHEN INSERTING THEN 'INSERT'
                          WHEN UPDATING  THEN 'UPDATE'
                          ELSE                'DELETE' END;
   END BEFORE STATEMENT;

   AFTER EACH ROW IS
   BEGIN
      v_filas     := v_filas + 1;
      v_id_tarifa := CASE WHEN DELETING THEN :OLD.id_tarifa ELSE :NEW.id_tarifa END;
      v_valor_ant := :OLD.valor_noche;
      v_valor_nue := :NEW.valor_noche;
   END AFTER EACH ROW;

   AFTER STATEMENT IS
   BEGIN
      IF v_filas > 0 THEN
         INSERT INTO auditoria_tarifa (usuario_bd, host_sesion, operacion,
                                       id_tarifa, valor_anterior, valor_nuevo,
                                       filas_afectadas)
         VALUES (USER, SYS_CONTEXT('USERENV', 'HOST'), v_operacion,
                 v_id_tarifa, v_valor_ant, v_valor_nue, v_filas);
      END IF;
   END AFTER STATEMENT;

END trg_tarifa_auditoria;
/

SHOW ERRORS TRIGGER trg_tarifa_auditoria


-- =====================================================================
-- 2) DISPARADOR DE FILA · anti-solapamiento de habitaciones
-- =====================================================================
-- Requisito: impedir que se registre una reserva que se solape con otra
-- de la MISMA habitación (condición estándar de solapamiento de rangos):
--     nueva.checkin < existente.checkout  AND  existente.checkin < nueva.checkout
-- excluyendo las reservas en estado CANCELADA (documentado desde la
-- Entrega 1 en docs/ROADMAP_Y_SUSTENTACION.md).
--
-- El problema de fondo: RESERVA_HABITACION no tiene fechas propias (viven
-- en la cabecera RESERVA), así que el disparador necesita LEER otra tabla
-- (RESERVA, sin problema) Y comparar contra las DEMÁS filas de su propia
-- tabla (RESERVA_HABITACION). Consultar la tabla que la sentencia está
-- modificando, desde un disparador de fila de esa misma tabla, dispara
-- ORA-04091 (tabla mutante) aunque el INSERT sea de una sola fila: Oracle
-- considera "mutante" la tabla durante TODA la sentencia, no solo cuando
-- inserta muchas filas.
--
-- La salida limpia es, otra vez, un COMPOUND TRIGGER: en AFTER EACH ROW
-- solo se ANOTA qué filas nuevas llegaron (sin consultar nada todavía); en
-- AFTER STATEMENT, cuando la sentencia ya terminó y la tabla deja de ser
-- mutante, se hace la consulta de solapamiento fila por fila anotada. Si
-- encuentra un cruce, lanza RAISE_APPLICATION_ERROR y toda la sentencia
-- (incluida la fila ya "insertada") se revierte: no queda nada a medias.
--
-- Esta es la MISMA regla de negocio que sp_crear_reserva ya valida antes
-- de insertar (código -20002): el procedimiento da un mensaje temprano y
-- claro; el disparador es la red de seguridad que protege el dato aunque
-- alguien haga un INSERT directo a RESERVA_HABITACION sin pasar por el
-- paquete.
-- =====================================================================
CREATE OR REPLACE TRIGGER trg_rh_anti_solape
   FOR INSERT OR UPDATE OF id_habitacion, id_reserva ON reserva_habitacion
   COMPOUND TRIGGER

   TYPE t_fila IS RECORD (
      id_reserva_habitacion reserva_habitacion.id_reserva_habitacion%TYPE,
      id_reserva            reserva_habitacion.id_reserva%TYPE,
      id_habitacion         reserva_habitacion.id_habitacion%TYPE
   );
   TYPE t_filas IS TABLE OF t_fila INDEX BY PLS_INTEGER;
   v_filas t_filas;
   v_n     PLS_INTEGER := 0;

   BEFORE STATEMENT IS
   BEGIN
      v_filas.DELETE;
      v_n := 0;
   END BEFORE STATEMENT;

   AFTER EACH ROW IS
   BEGIN
      v_n := v_n + 1;
      v_filas(v_n).id_reserva_habitacion := :NEW.id_reserva_habitacion;
      v_filas(v_n).id_reserva            := :NEW.id_reserva;
      v_filas(v_n).id_habitacion         := :NEW.id_habitacion;
   END AFTER EACH ROW;

   AFTER STATEMENT IS
      v_checkin  reserva.fecha_checkin%TYPE;
      v_checkout reserva.fecha_checkout%TYPE;
      v_choques  PLS_INTEGER;
   BEGIN
      FOR i IN 1 .. v_n LOOP
         SELECT fecha_checkin, fecha_checkout
           INTO v_checkin, v_checkout
           FROM reserva
          WHERE id_reserva = v_filas(i).id_reserva;

         SELECT COUNT(*) INTO v_choques
           FROM reserva_habitacion rh
           JOIN reserva r ON r.id_reserva = rh.id_reserva
          WHERE rh.id_habitacion         = v_filas(i).id_habitacion
            AND rh.id_reserva_habitacion <> v_filas(i).id_reserva_habitacion
            AND r.estado                <> 'CANCELADA'
            AND r.fecha_checkin  < v_checkout
            AND v_checkin        < r.fecha_checkout;

         IF v_choques > 0 THEN
            RAISE_APPLICATION_ERROR(-20002,
               'trg_rh_anti_solape: la habitación ' || v_filas(i).id_habitacion ||
               ' ya está reservada entre ' || TO_CHAR(v_checkin, 'YYYY-MM-DD') ||
               ' y ' || TO_CHAR(v_checkout, 'YYYY-MM-DD') || '.');
         END IF;
      END LOOP;
   END AFTER STATEMENT;

END trg_rh_anti_solape;
/

SHOW ERRORS TRIGGER trg_rh_anti_solape

PROMPT === Disparadores creados ===
SELECT trigger_name, triggering_event, table_name, status
  FROM user_triggers
 WHERE table_name IN ('TARIFA', 'RESERVA_HABITACION')
 ORDER BY trigger_name;
