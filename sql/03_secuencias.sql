-- =====================================================================
-- TurismoUQ · 03_secuencias.sql
-- Ejecutar como: TURISMO_UQ
--
-- Decisión de diseño: se usan SECUENCIAS explícitas (no IDENTITY) porque
--   a) el DDL queda legible y portable,
--   b) en la Entrega 2 sp_crear_reserva necesita el id ANTES de insertar
--      las filas hijas de RESERVA_HABITACION (v_id := seq_reserva.NEXTVAL),
--      lo cual es más simple que depender de RETURNING con IDENTITY.
-- Las columnas PK las declaran como DEFAULT seq.NEXTVAL (12c+), así que
-- un INSERT que omita la PK igual funciona.
--
-- CACHE alto en las secuencias de alto volumen: reduce contención en el
-- diccionario durante la carga de 25.000 reservas.
-- =====================================================================

CREATE SEQUENCE seq_municipio          START WITH 1 INCREMENT BY 1 NOCACHE  NOCYCLE;
CREATE SEQUENCE seq_tipo_alojamiento   START WITH 1 INCREMENT BY 1 NOCACHE  NOCYCLE;
CREATE SEQUENCE seq_alojamiento        START WITH 1 INCREMENT BY 1 CACHE 20 NOCYCLE;
CREATE SEQUENCE seq_habitacion         START WITH 1 INCREMENT BY 1 CACHE 50 NOCYCLE;
CREATE SEQUENCE seq_temporada          START WITH 1 INCREMENT BY 1 CACHE 20 NOCYCLE;
CREATE SEQUENCE seq_tarifa             START WITH 1 INCREMENT BY 1 CACHE 500 NOCYCLE;
CREATE SEQUENCE seq_cliente            START WITH 1 INCREMENT BY 1 CACHE 100 NOCYCLE;
CREATE SEQUENCE seq_reserva            START WITH 1 INCREMENT BY 1 CACHE 500 NOCYCLE;
CREATE SEQUENCE seq_reserva_habitacion START WITH 1 INCREMENT BY 1 CACHE 500 NOCYCLE;
CREATE SEQUENCE seq_pago               START WITH 1 INCREMENT BY 1 CACHE 500 NOCYCLE;
CREATE SEQUENCE seq_servicio           START WITH 1 INCREMENT BY 1 NOCACHE  NOCYCLE;
CREATE SEQUENCE seq_reserva_servicio   START WITH 1 INCREMENT BY 1 CACHE 500 NOCYCLE;
CREATE SEQUENCE seq_resena             START WITH 1 INCREMENT BY 1 CACHE 100 NOCYCLE;
CREATE SEQUENCE seq_usuario_sistema    START WITH 1 INCREMENT BY 1 CACHE 20 NOCYCLE;
CREATE SEQUENCE seq_auditoria_tarifa   START WITH 1 INCREMENT BY 1 CACHE 20 NOCYCLE;

SELECT sequence_name, cache_size FROM user_sequences ORDER BY sequence_name;
