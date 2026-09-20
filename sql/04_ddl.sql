-- =====================================================================
-- TurismoUQ · 04_ddl.sql
-- Ejecutar como: TURISMO_UQ
-- Oracle XE 21c
--
-- 14 entidades exigidas + 3 entidades adicionales justificadas:
--   CATEGORIA_HABITACION  -> convierte un CHECK de texto en una FK real
--   DIM_TIEMPO            -> calendario 2024-2026, base del cálculo de
--                            noches, ocupación y temporadas atravesadas
--   AUDITORIA_TARIFA      -> destino del disparador de sentencia (Entrega 2)
--
-- Convención de nombres de constraints:
--   pk_<tabla> · fk_<tabla>_<tabla_padre> · uq_<tabla>_<columnas>
--   ck_<tabla>_<regla> · ix_<tabla>_<columnas>
--
-- Ubicación física:
--   ts_turismo_dat  -> catálogo (poco volumen, casi sin cambios)
--   ts_turismo_hist -> histórico transaccional (95 % de las filas)
--   ts_turismo_idx  -> todos los índices
-- =====================================================================

SET ECHO ON

-- =====================================================================
-- BLOQUE 1 · CATÁLOGO GEOGRÁFICO Y DE OFERTA
-- =====================================================================

CREATE TABLE municipio (
   id_municipio    NUMBER(4)     DEFAULT seq_municipio.NEXTVAL,
   nombre          VARCHAR2(60)  NOT NULL,
   codigo_dane     CHAR(5)       NOT NULL,
   altitud_msnm    NUMBER(5)     NOT NULL,
   poblacion       NUMBER(8),
   CONSTRAINT pk_municipio        PRIMARY KEY (id_municipio)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_municipio_nombre UNIQUE (nombre)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_municipio_dane   UNIQUE (codigo_dane)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_municipio_alt    CHECK (altitud_msnm BETWEEN 500 AND 3500),
   CONSTRAINT ck_municipio_pob    CHECK (poblacion IS NULL OR poblacion > 0)
) TABLESPACE ts_turismo_dat;

COMMENT ON TABLE municipio IS 'Los 12 municipios del departamento del Quindío';

CREATE TABLE tipo_alojamiento (
   id_tipo         NUMBER(3)     DEFAULT seq_tipo_alojamiento.NEXTVAL,
   nombre          VARCHAR2(30)  NOT NULL,
   descripcion     VARCHAR2(200),
   CONSTRAINT pk_tipo_alojamiento    PRIMARY KEY (id_tipo)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_tipo_alojam_nombre  UNIQUE (nombre)
      USING INDEX TABLESPACE ts_turismo_idx
) TABLESPACE ts_turismo_dat;

-- Entidad adicional (decisión de diseño):
-- la categoría de habitación es a la vez atributo de HABITACION y clave de
-- TARIFA. Si fuera un VARCHAR2 con CHECK en dos tablas, nada garantizaría que
-- ambas listas coincidan. Como tabla, la integridad la impone el motor.
CREATE TABLE categoria_habitacion (
   codigo          VARCHAR2(20)  NOT NULL,
   descripcion     VARCHAR2(120) NOT NULL,
   factor_precio   NUMBER(4,2)   DEFAULT 1 NOT NULL,
   CONSTRAINT pk_categoria_habitacion PRIMARY KEY (codigo)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_categoria_factor     CHECK (factor_precio > 0)
) TABLESPACE ts_turismo_dat;

CREATE TABLE alojamiento (
   id_alojamiento  NUMBER(6)     DEFAULT seq_alojamiento.NEXTVAL,
   id_municipio    NUMBER(4)     NOT NULL,
   id_tipo         NUMBER(3)     NOT NULL,
   nombre          VARCHAR2(120) NOT NULL,
   direccion       VARCHAR2(150) NOT NULL,
   telefono        VARCHAR2(20),
   email           VARCHAR2(120),
   estrellas       NUMBER(1),
   fecha_registro  DATE          DEFAULT TRUNC(SYSDATE) NOT NULL,
   activo          CHAR(1)       DEFAULT 'S' NOT NULL,
   CONSTRAINT pk_alojamiento        PRIMARY KEY (id_alojamiento)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_alojam_municipio   FOREIGN KEY (id_municipio)
      REFERENCES municipio (id_municipio),
   CONSTRAINT fk_alojam_tipo        FOREIGN KEY (id_tipo)
      REFERENCES tipo_alojamiento (id_tipo),
   CONSTRAINT uq_alojam_mun_nombre  UNIQUE (id_municipio, nombre)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_alojam_estrellas   CHECK (estrellas IS NULL OR estrellas BETWEEN 1 AND 5),
   CONSTRAINT ck_alojam_activo      CHECK (activo IN ('S','N')),
   CONSTRAINT ck_alojam_email       CHECK (email IS NULL OR INSTR(email,'@') > 1)
) TABLESPACE ts_turismo_dat;

CREATE TABLE habitacion (
   id_habitacion   NUMBER(6)     DEFAULT seq_habitacion.NEXTVAL,
   id_alojamiento  NUMBER(6)     NOT NULL,
   numero          VARCHAR2(10)  NOT NULL,
   categoria       VARCHAR2(20)  NOT NULL,
   capacidad       NUMBER(2)     NOT NULL,
   activa          CHAR(1)       DEFAULT 'S' NOT NULL,
   CONSTRAINT pk_habitacion        PRIMARY KEY (id_habitacion)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_habitacion_alojam FOREIGN KEY (id_alojamiento)
      REFERENCES alojamiento (id_alojamiento),
   CONSTRAINT fk_habitacion_categ  FOREIGN KEY (categoria)
      REFERENCES categoria_habitacion (codigo),
   CONSTRAINT uq_habitacion_numero UNIQUE (id_alojamiento, numero)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_habitacion_cap    CHECK (capacidad BETWEEN 1 AND 10),
   CONSTRAINT ck_habitacion_activa CHECK (activa IN ('S','N'))
) TABLESPACE ts_turismo_dat;

-- =====================================================================
-- BLOQUE 2 · TEMPORADAS Y TARIFAS  (núcleo de la decisión de diseño B)
-- =====================================================================

-- TEMPORADA es un rango de fechas del calendario, NO un atributo de la reserva.
-- Las temporadas cargadas son disjuntas y cubren 2024-01-01 .. 2026-12-31.
-- Oracle no tiene constraint de exclusión de rangos: la no superposición se
-- garantiza en la carga y se validará con disparador en la Entrega 2.
CREATE TABLE temporada (
   id_temporada    NUMBER(5)     DEFAULT seq_temporada.NEXTVAL,
   nombre          VARCHAR2(60)  NOT NULL,
   tipo            VARCHAR2(5)   NOT NULL,
   fecha_inicio    DATE          NOT NULL,
   fecha_fin       DATE          NOT NULL,
   factor          NUMBER(4,2)   DEFAULT 1 NOT NULL,
   CONSTRAINT pk_temporada        PRIMARY KEY (id_temporada)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_temporada_nombre UNIQUE (nombre)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_temporada_inicio UNIQUE (fecha_inicio)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_temporada_tipo   CHECK (tipo IN ('ALTA','MEDIA','BAJA')),
   CONSTRAINT ck_temporada_rango  CHECK (fecha_fin >= fecha_inicio),
   CONSTRAINT ck_temporada_factor CHECK (factor BETWEEN 0.5 AND 5),
   CONSTRAINT ck_temporada_horas  CHECK (fecha_inicio = TRUNC(fecha_inicio)
                                     AND fecha_fin    = TRUNC(fecha_fin))
) TABLESPACE ts_turismo_dat;

-- Precio por noche de una (alojamiento, categoría, temporada).
-- Grano elegido a propósito: NO se tarifa por habitación individual, porque
-- todas las habitaciones de la misma categoría en el mismo hotel valen igual.
-- Reduce de ~40.000 a ~18.000 filas y hace determinista el precio.
CREATE TABLE tarifa (
   id_tarifa       NUMBER(8)     DEFAULT seq_tarifa.NEXTVAL,
   id_alojamiento  NUMBER(6)     NOT NULL,
   categoria       VARCHAR2(20)  NOT NULL,
   id_temporada    NUMBER(5)     NOT NULL,
   valor_noche     NUMBER(10,2)  NOT NULL,
   CONSTRAINT pk_tarifa          PRIMARY KEY (id_tarifa)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_tarifa_alojam   FOREIGN KEY (id_alojamiento)
      REFERENCES alojamiento (id_alojamiento),
   CONSTRAINT fk_tarifa_categ    FOREIGN KEY (categoria)
      REFERENCES categoria_habitacion (codigo),
   CONSTRAINT fk_tarifa_temp     FOREIGN KEY (id_temporada)
      REFERENCES temporada (id_temporada),
   -- Clave de negocio: una sola tarifa vigente por combinación.
   -- Este índice único es además el camino de acceso de fn_valor_estadia.
   CONSTRAINT uq_tarifa_natural  UNIQUE (id_alojamiento, categoria, id_temporada)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_tarifa_valor    CHECK (valor_noche > 0)
) TABLESPACE ts_turismo_dat;

-- Calendario. Entidad adicional (decisión de diseño).
-- Cada día de 2024-2026 apunta a exactamente una temporada. Con esto:
--   · contar noches de una estadía = contar filas
--   · "qué temporadas atraviesa una estadía" = un JOIN por rango
--   · la ocupación mensual se calcula sin generar fechas con CONNECT BY
CREATE TABLE dim_tiempo (
   fecha           DATE          NOT NULL,
   anio            NUMBER(4)     NOT NULL,
   mes             NUMBER(2)     NOT NULL,
   dia             NUMBER(2)     NOT NULL,
   anio_mes        CHAR(7)       NOT NULL,
   nombre_mes      VARCHAR2(15)  NOT NULL,
   trimestre       NUMBER(1)     NOT NULL,
   dia_semana      NUMBER(1)     NOT NULL,
   es_fin_semana   CHAR(1)       NOT NULL,
   id_temporada    NUMBER(5)     NOT NULL,
   CONSTRAINT pk_dim_tiempo      PRIMARY KEY (fecha)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_dim_tiempo_temp FOREIGN KEY (id_temporada)
      REFERENCES temporada (id_temporada),
   CONSTRAINT ck_dim_mes         CHECK (mes BETWEEN 1 AND 12),
   CONSTRAINT ck_dim_trim        CHECK (trimestre BETWEEN 1 AND 4),
   CONSTRAINT ck_dim_dsem        CHECK (dia_semana BETWEEN 1 AND 7),
   CONSTRAINT ck_dim_finsem      CHECK (es_fin_semana IN ('S','N')),
   CONSTRAINT ck_dim_trunc       CHECK (fecha = TRUNC(fecha))
) TABLESPACE ts_turismo_dat;

-- =====================================================================
-- BLOQUE 3 · CLIENTES Y USUARIOS
-- =====================================================================

CREATE TABLE cliente (
   id_cliente       NUMBER(7)     DEFAULT seq_cliente.NEXTVAL,
   tipo_documento   VARCHAR2(3)   NOT NULL,
   numero_documento VARCHAR2(20)  NOT NULL,
   nombres          VARCHAR2(60)  NOT NULL,
   apellidos        VARCHAR2(60)  NOT NULL,
   email            VARCHAR2(120) NOT NULL,
   telefono         VARCHAR2(20),
   fecha_nacimiento DATE,
   pais             VARCHAR2(40)  DEFAULT 'Colombia' NOT NULL,
   ciudad_origen    VARCHAR2(60),
   fecha_registro   DATE          DEFAULT TRUNC(SYSDATE) NOT NULL,
   CONSTRAINT pk_cliente          PRIMARY KEY (id_cliente)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_cliente_doc      UNIQUE (tipo_documento, numero_documento)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_cliente_email    UNIQUE (email)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_cliente_tipodoc  CHECK (tipo_documento IN ('CC','CE','PAS','TI','NIT')),
   CONSTRAINT ck_cliente_email    CHECK (INSTR(email,'@') > 1),
   -- No se puede usar SYSDATE en un CHECK (debe ser determinista):
   -- la validación "no puede ser futura" queda para PL/SQL en la Entrega 2.
   CONSTRAINT ck_cliente_fnac     CHECK (fecha_nacimiento IS NULL
                                     OR fecha_nacimiento >= DATE '1910-01-01')
) TABLESPACE ts_turismo_dat;

-- Usuarios de la plataforma. Los cuatro roles de la Entrega 3 ya viven aquí.
CREATE TABLE usuario_sistema (
   id_usuario      NUMBER(6)     DEFAULT seq_usuario_sistema.NEXTVAL,
   username        VARCHAR2(30)  NOT NULL,
   nombre_completo VARCHAR2(120) NOT NULL,
   email           VARCHAR2(120) NOT NULL,
   rol             VARCHAR2(20)  NOT NULL,
   id_alojamiento  NUMBER(6),
   activo          CHAR(1)       DEFAULT 'S' NOT NULL,
   fecha_creacion  DATE          DEFAULT SYSDATE NOT NULL,
   CONSTRAINT pk_usuario_sistema   PRIMARY KEY (id_usuario)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_usuario_username  UNIQUE (username)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_usuario_email     UNIQUE (email)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_usuario_alojam    FOREIGN KEY (id_alojamiento)
      REFERENCES alojamiento (id_alojamiento),
   CONSTRAINT ck_usuario_rol       CHECK (rol IN
      ('RECEPCION','ADMIN_ALOJAMIENTO','GERENTE','AUDITOR')),
   CONSTRAINT ck_usuario_activo    CHECK (activo IN ('S','N')),
   -- Regla de negocio: recepción y administrador pertenecen a UN alojamiento;
   -- gerente y auditor son transversales al departamento.
   CONSTRAINT ck_usuario_ambito    CHECK (
        (rol IN ('RECEPCION','ADMIN_ALOJAMIENTO') AND id_alojamiento IS NOT NULL)
     OR (rol IN ('GERENTE','AUDITOR')             AND id_alojamiento IS NULL))
) TABLESPACE ts_turismo_dat;

-- =====================================================================
-- BLOQUE 4 · SERVICIOS COMPLEMENTARIOS (catálogo)
-- =====================================================================

CREATE TABLE servicio (
   id_servicio     NUMBER(5)     DEFAULT seq_servicio.NEXTVAL,
   nombre          VARCHAR2(80)  NOT NULL,
   categoria       VARCHAR2(20)  NOT NULL,
   precio_base     NUMBER(10,2)  NOT NULL,
   unidad_medida   VARCHAR2(20)  DEFAULT 'UNIDAD' NOT NULL,
   activo          CHAR(1)       DEFAULT 'S' NOT NULL,
   CONSTRAINT pk_servicio         PRIMARY KEY (id_servicio)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT uq_servicio_nombre  UNIQUE (nombre)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_servicio_precio  CHECK (precio_base > 0),
   CONSTRAINT ck_servicio_activo  CHECK (activo IN ('S','N')),
   CONSTRAINT ck_servicio_categ   CHECK (categoria IN
      ('ALIMENTACION','TOUR','TRANSPORTE','BIENESTAR','RECREACION','OTRO'))
) TABLESPACE ts_turismo_dat;

-- =====================================================================
-- BLOQUE 5 · HISTÓRICO TRANSACCIONAL  -> ts_turismo_hist
-- =====================================================================

-- Decisión de diseño A: la RESERVA es la cabecera del contrato y NO conoce
-- la habitación. Las fechas de la estadía viven en la cabecera porque todas
-- las habitaciones de una misma reserva comparten check-in y check-out
-- (es una estadía, no varias). Alternativa descartada: fechas por habitación,
-- que permitiría estadías escalonadas pero rompería la semántica de "reserva".
CREATE TABLE reserva (
   id_reserva        NUMBER(8)     DEFAULT seq_reserva.NEXTVAL,
   id_cliente        NUMBER(7)     NOT NULL,
   id_alojamiento    NUMBER(6)     NOT NULL,
   fecha_reserva     DATE          NOT NULL,
   fecha_checkin     DATE          NOT NULL,
   fecha_checkout    DATE          NOT NULL,
   num_huespedes     NUMBER(3)     NOT NULL,
   estado            VARCHAR2(15)  DEFAULT 'PENDIENTE' NOT NULL,
   canal             VARCHAR2(15)  DEFAULT 'WEB' NOT NULL,
   valor_alojamiento NUMBER(12,2)  DEFAULT 0 NOT NULL,
   valor_servicios   NUMBER(12,2)  DEFAULT 0 NOT NULL,
   -- Columna virtual: no ocupa espacio, no puede desincronizarse y es
   -- candidata natural a índice basado en función en la Entrega 3.
   valor_total       NUMBER(12,2)  GENERATED ALWAYS AS
                     (valor_alojamiento + valor_servicios) VIRTUAL,
   observaciones     VARCHAR2(300),
   CONSTRAINT pk_reserva          PRIMARY KEY (id_reserva)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_reserva_cliente  FOREIGN KEY (id_cliente)
      REFERENCES cliente (id_cliente),
   CONSTRAINT fk_reserva_alojam   FOREIGN KEY (id_alojamiento)
      REFERENCES alojamiento (id_alojamiento),
   -- Requisito del documento: checkout posterior al checkin.
   CONSTRAINT ck_reserva_fechas   CHECK (fecha_checkout > fecha_checkin),
   CONSTRAINT ck_reserva_anticip  CHECK (fecha_reserva <= fecha_checkin),
   CONSTRAINT ck_reserva_trunc    CHECK (fecha_checkin  = TRUNC(fecha_checkin)
                                     AND fecha_checkout = TRUNC(fecha_checkout)),
   CONSTRAINT ck_reserva_huesped  CHECK (num_huespedes BETWEEN 1 AND 40),
   CONSTRAINT ck_reserva_estado   CHECK (estado IN
      ('PENDIENTE','CONFIRMADA','CANCELADA','COMPLETADA','NO_SHOW')),
   CONSTRAINT ck_reserva_canal    CHECK (canal IN
      ('WEB','TELEFONO','AGENCIA','PRESENCIAL')),
   CONSTRAINT ck_reserva_valores  CHECK (valor_alojamiento >= 0
                                     AND valor_servicios   >= 0)
) TABLESPACE ts_turismo_hist;

COMMENT ON TABLE reserva IS
   'Cabecera de reserva. Histórico 2024-2026. Reside en ts_turismo_hist.';

-- Tabla puente RESERVA (1:N) RESERVA_HABITACION (N:1) HABITACION.
-- Resuelve la relación N:M entre reservas y habitaciones y da lugar donde
-- guardar los atributos propios del vínculo (huéspedes y valor de esa
-- habitación en esa estadía).
CREATE TABLE reserva_habitacion (
   id_reserva_habitacion NUMBER(9) DEFAULT seq_reserva_habitacion.NEXTVAL,
   id_reserva            NUMBER(8)    NOT NULL,
   id_habitacion         NUMBER(6)    NOT NULL,
   huespedes             NUMBER(2)    DEFAULT 1 NOT NULL,
   valor_noches          NUMBER(12,2) DEFAULT 0 NOT NULL,
   CONSTRAINT pk_reserva_habitacion PRIMARY KEY (id_reserva_habitacion)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_rh_reserva     FOREIGN KEY (id_reserva)
      REFERENCES reserva (id_reserva) ON DELETE CASCADE,
   CONSTRAINT fk_rh_habitacion  FOREIGN KEY (id_habitacion)
      REFERENCES habitacion (id_habitacion),
   -- La misma habitación no puede repetirse dentro de la misma reserva.
   CONSTRAINT uq_rh_reserva_hab UNIQUE (id_reserva, id_habitacion)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_rh_huespedes   CHECK (huespedes BETWEEN 1 AND 10),
   CONSTRAINT ck_rh_valor       CHECK (valor_noches >= 0)
) TABLESPACE ts_turismo_hist;

CREATE TABLE pago (
   id_pago       NUMBER(9)     DEFAULT seq_pago.NEXTVAL,
   id_reserva    NUMBER(8)     NOT NULL,
   fecha_pago    DATE          NOT NULL,
   valor         NUMBER(12,2)  NOT NULL,
   medio_pago    VARCHAR2(20)  NOT NULL,
   estado        VARCHAR2(15)  DEFAULT 'APROBADO' NOT NULL,
   referencia    VARCHAR2(30)  NOT NULL,
   CONSTRAINT pk_pago            PRIMARY KEY (id_pago)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_pago_reserva    FOREIGN KEY (id_reserva)
      REFERENCES reserva (id_reserva) ON DELETE CASCADE,
   CONSTRAINT uq_pago_referencia UNIQUE (referencia)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_pago_valor      CHECK (valor > 0),
   CONSTRAINT ck_pago_medio      CHECK (medio_pago IN
      ('EFECTIVO','TARJETA_CREDITO','TARJETA_DEBITO','PSE','TRANSFERENCIA')),
   CONSTRAINT ck_pago_estado     CHECK (estado IN ('APROBADO','RECHAZADO','REVERSADO'))
) TABLESPACE ts_turismo_hist;

CREATE TABLE reserva_servicio (
   id_reserva_servicio NUMBER(9)  DEFAULT seq_reserva_servicio.NEXTVAL,
   id_reserva          NUMBER(8)     NOT NULL,
   id_servicio         NUMBER(5)     NOT NULL,
   fecha_servicio      DATE          NOT NULL,
   cantidad            NUMBER(4)     DEFAULT 1 NOT NULL,
   valor_unitario      NUMBER(10,2)  NOT NULL,
   valor_total         NUMBER(12,2)  GENERATED ALWAYS AS
                       (cantidad * valor_unitario) VIRTUAL,
   CONSTRAINT pk_reserva_servicio PRIMARY KEY (id_reserva_servicio)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_rs_reserva   FOREIGN KEY (id_reserva)
      REFERENCES reserva (id_reserva) ON DELETE CASCADE,
   CONSTRAINT fk_rs_servicio  FOREIGN KEY (id_servicio)
      REFERENCES servicio (id_servicio),
   CONSTRAINT ck_rs_cantidad  CHECK (cantidad > 0),
   CONSTRAINT ck_rs_valor     CHECK (valor_unitario > 0)
) TABLESPACE ts_turismo_hist;

-- Una reseña por reserva (UNIQUE sobre la FK => relación 1:1 opcional).
-- Las cinco calificaciones separadas son el insumo del UNPIVOT (consulta 7).
CREATE TABLE resena (
   id_resena       NUMBER(8)     DEFAULT seq_resena.NEXTVAL,
   id_reserva      NUMBER(8)     NOT NULL,
   fecha_resena    DATE          NOT NULL,
   calif_general   NUMBER(1)     NOT NULL,
   calif_limpieza  NUMBER(1)     NOT NULL,
   calif_ubicacion NUMBER(1)     NOT NULL,
   calif_servicio  NUMBER(1)     NOT NULL,
   calif_precio    NUMBER(1)     NOT NULL,
   comentario      VARCHAR2(500),
   CONSTRAINT pk_resena         PRIMARY KEY (id_resena)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT fk_resena_reserva FOREIGN KEY (id_reserva)
      REFERENCES reserva (id_reserva) ON DELETE CASCADE,
   CONSTRAINT uq_resena_reserva UNIQUE (id_reserva)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_resena_general CHECK (calif_general   BETWEEN 1 AND 5),
   CONSTRAINT ck_resena_limp    CHECK (calif_limpieza  BETWEEN 1 AND 5),
   CONSTRAINT ck_resena_ubic    CHECK (calif_ubicacion BETWEEN 1 AND 5),
   CONSTRAINT ck_resena_serv    CHECK (calif_servicio  BETWEEN 1 AND 5),
   CONSTRAINT ck_resena_prec    CHECK (calif_precio    BETWEEN 1 AND 5)
) TABLESPACE ts_turismo_hist;

-- Preparada para el disparador de sentencia de la Entrega 2.
-- Se crea ahora para no tocar el DDL después. En la Entrega 1 queda vacía.
CREATE TABLE auditoria_tarifa (
   id_auditoria    NUMBER(9)     DEFAULT seq_auditoria_tarifa.NEXTVAL,
   fecha_hora      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
   usuario_bd      VARCHAR2(40)  DEFAULT USER NOT NULL,
   host_sesion     VARCHAR2(80),
   operacion       VARCHAR2(10)  NOT NULL,
   id_tarifa       NUMBER(8),
   valor_anterior  NUMBER(10,2),
   valor_nuevo     NUMBER(10,2),
   filas_afectadas NUMBER(8),
   CONSTRAINT pk_auditoria_tarifa PRIMARY KEY (id_auditoria)
      USING INDEX TABLESPACE ts_turismo_idx,
   CONSTRAINT ck_audtar_operacion CHECK (operacion IN ('INSERT','UPDATE','DELETE'))
) TABLESPACE ts_turismo_hist;

-- =====================================================================
-- BLOQUE 6 · ÍNDICES INICIALES
-- =====================================================================
-- Se crean SOLO los índices estructuralmente necesarios:
--   · claves foráneas de tablas hijas con borrado en cascada y alto volumen
--     (evitan bloqueos de tabla completa al modificar el padre),
--   · caminos que usa el generador de datos.
--
-- DELIBERADAMENTE NO SE CREAN (son el material de la Entrega 3):
--   · reserva(fecha_checkin, fecha_checkout)        -> índice compuesto
--   · reserva(id_alojamiento), reserva(id_cliente)  -> FK sin indexar
--   · función sobre fechas, p.ej. TRUNC(fecha_checkin,'MM') -> índice basado en función
--   · cualquier índice sobre reserva.estado         -> caso "el índice no ayuda"
-- =====================================================================

CREATE INDEX ix_alojam_municipio ON alojamiento (id_municipio)
   TABLESPACE ts_turismo_idx;
CREATE INDEX ix_alojam_tipo      ON alojamiento (id_tipo)
   TABLESPACE ts_turismo_idx;
CREATE INDEX ix_habitacion_aloj  ON habitacion (id_alojamiento)
   TABLESPACE ts_turismo_idx;
CREATE INDEX ix_rh_reserva       ON reserva_habitacion (id_reserva)
   TABLESPACE ts_turismo_idx;
CREATE INDEX ix_rh_habitacion    ON reserva_habitacion (id_habitacion)
   TABLESPACE ts_turismo_idx;
CREATE INDEX ix_pago_reserva     ON pago (id_reserva)
   TABLESPACE ts_turismo_idx;
CREATE INDEX ix_rs_reserva       ON reserva_servicio (id_reserva)
   TABLESPACE ts_turismo_idx;
CREATE INDEX ix_dim_tiempo_temp  ON dim_tiempo (id_temporada)
   TABLESPACE ts_turismo_idx;
CREATE INDEX ix_dim_tiempo_am    ON dim_tiempo (anio, mes)
   TABLESPACE ts_turismo_idx;

-- =====================================================================
PROMPT === Tablas creadas y su ubicación física ===
SELECT table_name, tablespace_name
  FROM user_tables
 ORDER BY tablespace_name, table_name;

PROMPT === Conteo de restricciones por tipo (P=PK, R=FK, U=UNIQUE, C=CHECK/NOT NULL) ===
SELECT constraint_type, COUNT(*) AS cantidad
  FROM user_constraints
 GROUP BY constraint_type
 ORDER BY constraint_type;
