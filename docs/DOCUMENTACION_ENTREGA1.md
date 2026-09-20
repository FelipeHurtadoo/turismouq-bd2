# TurismoUQ · Documentación de la Entrega 1

Bases de Datos II · código 12338 · periodo 2026-2
Motor: Oracle Database XE 21c · esquema `TURISMO_UQ` en el PDB `XEPDB1`

> **Convención usada en todo el documento**
> **[R]** = Requisito literal del documento del profesor.
> **[D]** = Decisión de diseño del equipo (no viene del enunciado; se justifica).

---

## FASE 1 — Análisis de requisitos

### 1.1 Requisitos por entrega

| Req | Descripción | Entrega | Dónde se resuelve |
|-----|-------------|---------|-------------------|
| R1  | 14 entidades mínimas, se puede agregar, no quitar | 1 | `04_ddl.sql` |
| R2  | DDL con PK, FK, CHECK, NOT NULL y UNIQUE | 1 | `04_ddl.sql` |
| R3  | Volumen: 12 / 60 / 400 / 3.000 / 25.000 / 40.000 | 1 | `05`, `06` |
| R4  | Reservas repartidas en 2024–2026 | 1 | `06` bloque C |
| R5  | Datos generados con PL/SQL y `DBMS_RANDOM` | 1 | `05`, `06` |
| R6  | Tablespace propio para el histórico de reservas + justificación | 1 | `01`, Fase 6 |
| R7  | Consulta con PIVOT (ocupación municipio × mes) | 1 | `08` C1 |
| R8  | ROLLUP o CUBE con GROUPING (ingresos) | 1 | `08` C2 |
| R9  | RANK con PARTITION BY (top 3 por municipio) | 1 | `08` C3 |
| R10 | LAG (variación mes contra mes) | 1 | `08` C4 |
| R11 | Consulta parametrizada con variables de enlace | 1 | `08` C5 |
| R12 | Vista materializada + política de refresco justificada | 1 | `07` |
| R13 | UNPIVOT | 1 | `08` C7 |
| R14 | Consulta libre de negocio | 1 | `08` C8 |
| R15 | `fn_valor_estadia` multi-temporada | 2 | soportado por el modelo |
| R16 | `sp_crear_reserva` con `RAISE_APPLICATION_ERROR` | 2 | soportado |
| R17 | Cursor explícito con parámetros (liquidación mensual) | 2 | soportado |
| R18 | Paquete que agrupe todo | 2 | soportado |
| R19 | Disparador de sentencia: auditoría de `TARIFA` | 2 | tabla `AUDITORIA_TARIFA` ya creada |
| R20 | Disparador de fila: impedir solapamiento | 2 | datos ya libres de solapamientos |
| R21 | Transacción atómica reserva+pago con `SAVEPOINT` | 3 | soportado |
| R22 | Experimento de concurrencia + `SELECT FOR UPDATE` | 3 | soportado |
| R23 | 3 consultas lentas, planes antes/después, índice compuesto, índice basado en función, un caso donde el índice no ayude | 3 | índices omitidos a propósito |
| R24 | 4 roles, recepción solo por vistas, perfil con límites | 3 | `USUARIO_SISTEMA` + vistas |
| R25 | Scripts numerados en orden de ejecución; deben correr en base limpia | todas | `README.md` |
| R26 | PDF con modelo y decisiones de diseño | 1 | este documento |

### 1.2 Ambigüedades detectadas y cómo se resolvieron **[D]**

| Ambigüedad | Decisión |
|---|---|
| El documento no define "ocupación" | Noches-habitación vendidas ÷ noches-habitación disponibles (estándar hotelero) |
| El documento no define "ingreso" | Ingreso **devengado**: suma de tarifas noche a noche de reservas `CONFIRMADA`/`COMPLETADA`. No se usan los pagos, porque un pago no sabe a qué temporada pertenece la noche que financia |
| No dice si la reserva tiene fechas o las tiene cada habitación | Fechas en la **cabecera** (`RESERVA`): una reserva es *una* estadía |
| No dice el grano de la tarifa | `(alojamiento, categoría, temporada)`; ver Fase 2 |
| No dice si las temporadas cubren todo el calendario | Sí: disjuntas y sin huecos, condición necesaria para que `fn_valor_estadia` nunca encuentre una noche sin tarifa |
| "25.000 reservas repartidas en 2024–2026" | Se reparte por `fecha_checkin`, con sesgo estacional realista |

---

## FASE 2 — Arquitectura y decisiones críticas

### 2.1 Las tres capas del modelo

```
CATÁLOGO (cambia poco)        TEMPORAL              HISTÓRICO (crece siempre)
ts_turismo_dat                ts_turismo_dat        ts_turismo_hist
──────────────────────        ─────────────         ────────────────────────
MUNICIPIO                     TEMPORADA             RESERVA
TIPO_ALOJAMIENTO              DIM_TIEMPO            RESERVA_HABITACION
CATEGORIA_HABITACION          TARIFA                PAGO
ALOJAMIENTO                                         RESERVA_SERVICIO
HABITACION                                          RESENA
CLIENTE                                             AUDITORIA_TARIFA
SERVICIO
USUARIO_SISTEMA
```

### 2.2 Decisión A **[R obligatoria de defender]** — una reserva con varias habitaciones

**Alternativas evaluadas**

| Alternativa | Ventaja | Por qué se descarta |
|---|---|---|
| 1. `RESERVA.id_habitacion` (FK directa) | trivial | Solo admite una habitación. Una familia que toma tres cabañas necesitaría tres reservas, tres pagos y tres reseñas de la misma estadía. **Viola 1FN en el sentido práctico**: obliga a repetir toda la cabecera |
| 2. Lista de habitaciones en un `VARCHAR2` separada por comas | "cabe" | Rompe 1FN de verdad, imposible de unir, imposible de indexar, imposible de validar con FK |
| 3. Tabla puente `RESERVA_HABITACION` | correcta y extensible | **ELEGIDA** |

**Diseño elegido**

```
RESERVA (1) ────< RESERVA_HABITACION >──── (1) HABITACION
```

`RESERVA_HABITACION` no es una tabla puente "vacía": tiene atributos propios del
vínculo — `huespedes` (cuántas personas van en *esa* habitación) y `valor_noches`
(cuánto costó *esa* habitación en *esa* estadía). Eso confirma que la relación
N:M entre reservas y habitaciones es una **entidad asociativa** legítima, no un
artificio.

Restricciones que la sostienen:
- `uq_rh_reserva_hab UNIQUE (id_reserva, id_habitacion)`: la misma habitación no
  puede aparecer dos veces en la misma reserva.
- `fk_rh_reserva ... ON DELETE CASCADE`: las líneas no sobreviven a su cabecera.
- La validación "la habitación pertenece al alojamiento de la reserva" **no puede
  ser una FK** (sería una dependencia transitiva); queda para `sp_crear_reserva`
  en la Entrega 2. El script `09_validacion.sql` comprueba que los datos
  cargados la cumplen.

### 2.3 Decisión B **[R obligatoria de defender]** — una estadía que atraviesa varias temporadas

Este es el corazón del proyecto. **La reserva NO tiene columna `id_temporada`.**

Poner `RESERVA.id_temporada` sería el error clásico: obligaría a elegir *una*
temporada para una estadía del 13 al 18 de diciembre, que es mitad baja y mitad
alta. Cualquier elección (la del check-in, la mayoritaria) falsea el ingreso.

**Diseño elegido: la temporada es una propiedad del CALENDARIO, no de la reserva.**

```
TEMPORADA (rango de fechas, disjunto y sin huecos)
     ▲
     │ 1:N
DIM_TIEMPO (un día = una fila = una temporada)
     ▲
     │ unión por rango:  d.fecha >= checkin AND d.fecha < checkout
RESERVA
```

El valor de una estadía se obtiene así:

```
por cada noche de [checkin, checkout):
      día → temporada (DIM_TIEMPO)
      (alojamiento, categoría, temporada) → tarifa de esa noche
sumar
```

Consecuencias que hay que saber defender:

1. **El rango es semiabierto `[checkin, checkout)`.** La noche de salida no se
   cobra: del 10 al 13 son 3 noches, no 4. Por eso el JOIN usa `>= checkin` y
   `< checkout`, nunca `BETWEEN`.
2. **Las temporadas cubren el calendario sin huecos ni superposiciones.** Si
   faltara un día, esa noche no tendría tarifa y el JOIN la perdería silenciosamente
   (el total saldría más barato sin error alguno). Por eso el generador construye
   las temporadas comprimiendo una clasificación día a día, y `09_validacion.sql`
   verifica ambas propiedades explícitamente.
3. **`fn_valor_estadia` de la Entrega 2 no exige ningún cambio de modelo**: es
   exactamente el `MERGE` del bloque D de `06_carga_masiva.sql` encapsulado en
   PL/SQL.

### 2.4 Grano de la tarifa **[D]**

`TARIFA (id_alojamiento, categoria, id_temporada) → valor_noche`, con UNIQUE
sobre esa terna.

| Alternativa | Filas | Problema |
|---|---|---|
| Tarifa por habitación × temporada | ~40.000 | Redundante: dos habitaciones estándar del mismo hotel siempre valen igual. Actualizar precios exigiría tocar N filas por hotel y podría desincronizarlas |
| Tarifa por tipo de alojamiento × temporada | ~600 | Insuficiente: dos fincas del mismo tipo no cobran lo mismo |
| **(alojamiento, categoría, temporada)** | ~18.000 | **ELEGIDA.** Sin redundancia y con precio determinista para cualquier habitación |

Como `fn_valor_estadia` recibe `id_habitacion`, la resolución es
`HABITACION → id_alojamiento + categoria → TARIFA`. El índice único
`uq_tarifa_natural` es precisamente el camino de acceso de esa función.

### 2.5 `DIM_TIEMPO`: por qué se agrega una entidad **[D]**

Es la única entidad adicional que altera la forma de consultar, así que merece
defensa. Alternativa: generar las fechas al vuelo con
`CONNECT BY LEVEL <= checkout - checkin`. Se descartó porque:

- habría que repetir esa generación en cada consulta y en cada función;
- impide indexar y calcular estadísticas sobre las fechas;
- no permite guardar la clasificación por temporada, obligando a un `BETWEEN`
  contra `TEMPORADA` en cada consulta (una unión por rango, mucho más cara que
  una igualdad);
- el calendario es además el denominador de la ocupación (días del mes) y el
  vocabulario común de las 8 consultas (`anio_mes`, `trimestre`, `es_fin_semana`).

Es la tabla de dimensión de tiempo clásica de cualquier modelo analítico.

### 2.6 Normalización

Todo el modelo está en **3FN**, y las excepciones son deliberadas:

- `RESERVA.valor_alojamiento` y `valor_servicios` son **redundancia calculada**
  aceptada a conciencia: recalcular el total de 25.000 reservas explotando sus
  noches cuesta segundos; el mostrador necesita el total en milisegundos. Se
  documenta como desnormalización controlada, y en la Entrega 2 el paquete es el
  único punto que la mantiene.
- `RESERVA.valor_total` es **columna virtual**: no se almacena, se calcula al
  leer. No puede desincronizarse por construcción.
- `RESERVA_SERVICIO.valor_total` (= `cantidad × valor_unitario`), igual.
- `RESERVA_SERVICIO.valor_unitario` **no** es redundante frente a
  `SERVICIO.precio_base`: guarda el precio *histórico* del día en que se prestó.
  Si mañana sube el tour del café, las facturas del año pasado no deben cambiar.

---

## FASE 3 — Modelo lógico

### 3.1 Relaciones y cardinalidades

| Relación | Card. | Opcionalidad |
|---|---|---|
| MUNICIPIO – ALOJAMIENTO | 1:N | un alojamiento siempre tiene municipio |
| TIPO_ALOJAMIENTO – ALOJAMIENTO | 1:N | obligatoria |
| ALOJAMIENTO – HABITACION | 1:N | obligatoria |
| CATEGORIA_HABITACION – HABITACION | 1:N | obligatoria |
| ALOJAMIENTO – TARIFA | 1:N | obligatoria |
| TEMPORADA – TARIFA | 1:N | obligatoria |
| TEMPORADA – DIM_TIEMPO | 1:N | cada día tiene exactamente una temporada |
| CLIENTE – RESERVA | 1:N | obligatoria |
| ALOJAMIENTO – RESERVA | 1:N | obligatoria |
| **RESERVA – HABITACION** | **N:M** | resuelta por `RESERVA_HABITACION` |
| RESERVA – PAGO | 1:N | opcional (una reserva pendiente aún no pagó) |
| **RESERVA – SERVICIO** | **N:M** | resuelta por `RESERVA_SERVICIO` |
| RESERVA – RESENA | 1:0..1 | opcional; `UNIQUE(id_reserva)` impone el máximo |
| ALOJAMIENTO – USUARIO_SISTEMA | 1:N | opcional: gerente y auditor no tienen alojamiento |

### 3.2 Diccionario de datos

#### MUNICIPIO — los 12 municipios del Quindío
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_municipio | NUMBER(4) | PK, DEFAULT secuencia | Identificador |
| nombre | VARCHAR2(60) | NOT NULL, UNIQUE | Nombre oficial |
| codigo_dane | CHAR(5) | NOT NULL, UNIQUE | Código DANE real (63xxx) |
| altitud_msnm | NUMBER(5) | NOT NULL, CHECK 500–3500 | Altitud; relevante en turismo de montaña |
| poblacion | NUMBER(8) | CHECK > 0 | Población aproximada |

#### TIPO_ALOJAMIENTO — finca, hotel, glamping, hostal, cabaña, apartahotel
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_tipo | NUMBER(3) | PK | Identificador |
| nombre | VARCHAR2(30) | NOT NULL, UNIQUE | Tipo |
| descripcion | VARCHAR2(200) | | Detalle |

#### CATEGORIA_HABITACION **[D]** — estándar, superior, suite
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| codigo | VARCHAR2(20) | PK | Código de categoría |
| descripcion | VARCHAR2(120) | NOT NULL | Detalle |
| factor_precio | NUMBER(4,2) | NOT NULL, CHECK > 0 | Multiplicador sobre el precio base |

#### ALOJAMIENTO
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_alojamiento | NUMBER(6) | PK | Identificador |
| id_municipio | NUMBER(4) | FK, NOT NULL | Ubicación |
| id_tipo | NUMBER(3) | FK, NOT NULL | Tipo |
| nombre | VARCHAR2(120) | NOT NULL, UNIQUE con municipio | Nombre comercial |
| direccion | VARCHAR2(150) | NOT NULL | Dirección |
| telefono / email | VARCHAR2 | CHECK de formato en email | Contacto |
| estrellas | NUMBER(1) | CHECK 1–5 | Categoría turística |
| fecha_registro | DATE | NOT NULL, DEFAULT | Alta en la plataforma |
| activo | CHAR(1) | NOT NULL, CHECK S/N | Baja lógica (no se borra: hay histórico) |

#### HABITACION
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_habitacion | NUMBER(6) | PK | Identificador |
| id_alojamiento | NUMBER(6) | FK, NOT NULL | Propietario |
| numero | VARCHAR2(10) | NOT NULL, UNIQUE con alojamiento | Número visible |
| categoria | VARCHAR2(20) | FK a CATEGORIA_HABITACION | Determina la tarifa |
| capacidad | NUMBER(2) | NOT NULL, CHECK 1–10 | Huéspedes máximos |
| activa | CHAR(1) | NOT NULL, CHECK S/N | Fuera de servicio sin borrarla |

#### TEMPORADA
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_temporada | NUMBER(5) | PK | Identificador |
| nombre | VARCHAR2(60) | NOT NULL, UNIQUE | Etiqueta legible |
| tipo | VARCHAR2(5) | CHECK ALTA/MEDIA/BAJA | Clasificación |
| fecha_inicio / fecha_fin | DATE | NOT NULL, CHECK fin ≥ inicio, CHECK sin hora | Rango cerrado |
| factor | NUMBER(4,2) | CHECK 0,5–5 | Multiplicador estacional |

#### TARIFA
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_tarifa | NUMBER(8) | PK | Identificador |
| id_alojamiento / categoria / id_temporada | FK | UNIQUE los tres juntos | Clave de negocio |
| valor_noche | NUMBER(10,2) | NOT NULL, CHECK > 0 | Precio COP por noche |

#### DIM_TIEMPO **[D]**
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| fecha | DATE | PK, CHECK sin hora | Día del calendario 2024–2026 |
| anio, mes, dia, trimestre, dia_semana | NUMBER | CHECK de rango | Atributos derivados |
| anio_mes | CHAR(7) | NOT NULL | 'YYYY-MM', clave de agrupación mensual |
| nombre_mes | VARCHAR2(15) | NOT NULL | En español, sin depender del NLS |
| es_fin_semana | CHAR(1) | CHECK S/N | Sábado o domingo |
| id_temporada | NUMBER(5) | FK, NOT NULL | Temporada de ese día |

#### CLIENTE
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_cliente | NUMBER(7) | PK | Identificador |
| tipo_documento + numero_documento | | UNIQUE juntos, CHECK de tipo | Identidad |
| nombres / apellidos | VARCHAR2(60) | NOT NULL | Datos ficticios |
| email | VARCHAR2(120) | NOT NULL, UNIQUE, CHECK contiene @ | Contacto |
| fecha_nacimiento | DATE | CHECK ≥ 1910 | Ver nota sobre SYSDATE |
| pais / ciudad_origen | VARCHAR2 | | Origen del turista |

#### RESERVA — cabecera del histórico
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_reserva | NUMBER(8) | PK | Identificador |
| id_cliente / id_alojamiento | FK NOT NULL | | Quién y dónde |
| fecha_reserva | DATE | NOT NULL, CHECK ≤ checkin | Cuándo se hizo |
| fecha_checkin / fecha_checkout | DATE | NOT NULL, **CHECK checkout > checkin** | La estadía |
| num_huespedes | NUMBER(3) | CHECK 1–40 | Total de personas |
| estado | VARCHAR2(15) | CHECK de 5 valores | Ciclo de vida |
| canal | VARCHAR2(15) | CHECK de 4 valores | Origen de la venta |
| valor_alojamiento / valor_servicios | NUMBER(12,2) | CHECK ≥ 0 | Totales mantenidos |
| valor_total | NUMBER(12,2) | **columna virtual** | Suma de los dos anteriores |

#### RESERVA_HABITACION — entidad asociativa
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_reserva_habitacion | NUMBER(9) | PK | Identificador |
| id_reserva | FK ON DELETE CASCADE | UNIQUE con habitación | Cabecera |
| id_habitacion | FK | | Habitación asignada |
| huespedes | NUMBER(2) | CHECK 1–10 | Personas en esa habitación |
| valor_noches | NUMBER(12,2) | CHECK ≥ 0 | Valor multi-temporada de esa habitación |

#### PAGO
| Columna | Tipo | Restricción | Descripción |
|---|---|---|---|
| id_pago | NUMBER(9) | PK | Identificador |
| id_reserva | FK ON DELETE CASCADE | | Reserva pagada |
| fecha_pago | DATE | NOT NULL | Fecha |
| valor | NUMBER(12,2) | CHECK > 0 | Importe (permite anticipos) |
| medio_pago | VARCHAR2(20) | CHECK de 5 valores | Medio |
| estado | VARCHAR2(15) | CHECK APROBADO/RECHAZADO/REVERSADO | Resultado |
| referencia | VARCHAR2(30) | NOT NULL, UNIQUE | Referencia de la pasarela |

#### SERVICIO / RESERVA_SERVICIO
`SERVICIO` es el catálogo (nombre único, categoría, precio base).
`RESERVA_SERVICIO` es el consumo: fecha, cantidad, `valor_unitario` histórico y
`valor_total` virtual. FK a reserva con borrado en cascada.

#### RESENA
Una por reserva (`UNIQUE(id_reserva)`), con cinco calificaciones 1–5
(`CHECK` en cada una) y comentario. Las cinco columnas son el insumo del UNPIVOT.

#### USUARIO_SISTEMA
`username` y `email` únicos; `rol` restringido a los cuatro roles de la Entrega 3;
`id_alojamiento` obligatorio para `RECEPCION` y `ADMIN_ALOJAMIENTO`, y obligatoriamente
nulo para `GERENTE` y `AUDITOR` (un solo CHECK compuesto lo impone).

#### AUDITORIA_TARIFA **[D, preparada para la Entrega 2]**
Vacía en la Entrega 1. Registra operación, `id_tarifa`, valor anterior y nuevo,
usuario de base de datos (`DEFAULT USER`), marca de tiempo (`SYSTIMESTAMP`) y
filas afectadas.

### 3.3 Qué valida el motor y qué queda para PL/SQL

| Regla | Cómo se impone | Por qué |
|---|---|---|
| checkout > checkin | `CHECK` | Compara dos columnas de la misma fila |
| Calificación entre 1 y 5 | `CHECK` | Constante |
| Habitación única dentro de la reserva | `UNIQUE` | Clave compuesta |
| Una reseña por reserva | `UNIQUE` sobre la FK | |
| Rol coherente con alojamiento | `CHECK` compuesto | Misma fila |
| **Fecha de nacimiento no futura** | **PL/SQL (E2)** | `SYSDATE` no es determinista; Oracle prohíbe funciones no deterministas en un `CHECK` |
| **Habitación pertenece al alojamiento de la reserva** | **PL/SQL (E2)** | Involucra tres tablas |
| **Sin solapamiento de reservas** | **Disparador de fila (E2)** | Involucra otras filas de la misma tabla |
| **Capacidad no excedida** | **PL/SQL (E2)** | Requiere sumar las filas hijas |
| **Temporadas sin superposición** | **Disparador (E2)** | Oracle no tiene restricción de exclusión de rangos |
| **Reserva con al menos una habitación** | **PL/SQL (E2)** | Es una restricción de cardinalidad mínima; ninguna FK la expresa |

---

## FASE 4 — Estructura del repositorio

Ver `README.md`. El orden 01→09 es estricto: cada script solo referencia objetos
creados por los anteriores. `02_limpieza.sql` permite re-ejecutar la secuencia
completa sin recrear el usuario.

---

## FASE 6 — Tablespace del histórico de reservas **[R]**

### Qué se ubica ahí
`RESERVA`, `RESERVA_HABITACION`, `PAGO`, `RESERVA_SERVICIO`, `RESENA` y
`AUDITORIA_TARIFA` → `TS_TURISMO_HIST`.

### Por qué es "histórico"
Estas seis tablas comparten tres propiedades que ninguna tabla de catálogo tiene:

1. **Solo crecen.** Un municipio se crea una vez; las reservas se acumulan para
   siempre. Concentran más del 95 % de las filas y prácticamente el 100 % del
   crecimiento futuro.
2. **Son inmutables una vez cerradas.** Una reserva de 2024 ya completada no
   vuelve a modificarse. Son datos de solo lectura salvo en su ventana activa.
3. **Su patrón de acceso es distinto.** Se leen en barridos analíticos por rango
   de fechas; el catálogo se lee por clave y cabe en caché.

### Por qué conviene separarlo
- **Administración independiente:** el histórico puede pasarse a
  `READ ONLY` por periodos cerrados, respaldarse con otra frecuencia y crecer con
  su propia política de `AUTOEXTEND` sin arrastrar al catálogo.
- **Contención del crecimiento:** un error en el generador de datos llena
  `ts_turismo_hist` y no compromete el resto del esquema.
- **Respaldo y recuperación por tablespace:** RMAN opera a nivel de tablespace;
  separar permite recuperar el histórico sin tocar el catálogo, y viceversa.
- **Medición:** en la Entrega 3, `USER_SEGMENTS` filtrado por tablespace muestra
  exactamente cuánto ocupan los datos frente a cuánto ocupan los índices nuevos
  (que viven en `TS_TURISMO_IDX`).
- **Fragmentación:** datos e índices crecen de forma distinta; separarlos evita
  que sus extensiones se intercalen.

### Cómo se administra
```sql
-- Ver ocupación
SELECT tablespace_name, ROUND(SUM(bytes)/1024/1024,2) mb
  FROM user_segments GROUP BY tablespace_name;

-- Cerrar un periodo (requiere privilegio de administración)
ALTER TABLESPACE ts_turismo_hist READ ONLY;
ALTER TABLESPACE ts_turismo_hist READ WRITE;

-- Ampliar
ALTER DATABASE DATAFILE '.../ts_turismo_hist01.dbf' RESIZE 1G;
```

### Requisitos previos que hay que saber explicar
- Los `CREATE TABLESPACE` y `CREATE USER` se ejecutan como **SYSDBA dentro del
  PDB `XEPDB1`**, no en la raíz `CDB$ROOT` (en la raíz, un usuario nuevo tendría
  que llamarse `C##...`).
- **`CREATE TABLE` no basta**: sin `QUOTA` sobre el tablespace, el usuario recibe
  `ORA-01950: no privileges on tablespace`. Por eso el script otorga
  `QUOTA UNLIMITED` sobre los tres.
- La ruta del datafile debe existir en el servidor; se verifica con
  `SELECT name FROM v$datafile`.

### Limitaciones de Oracle XE 21c
- Máximo **12 GB de datos de usuario**, 2 GB de SGA y 2 hilos de CPU. El proyecto
  ocupa unos 250–400 MB, así que no es una restricción real aquí, pero conviene
  mencionarla.
- No hay Real Application Clusters ni Active Data Guard.
- Sobre **particionamiento**: las ediciones XE modernas incluyen varias opciones
  que antes eran exclusivas de Enterprise. Antes de afirmar nada en la
  sustentación, verifíquelo en su instalación con
  `SELECT * FROM v$option WHERE parameter = 'Partitioning';`.
  El modelo **no depende** del particionamiento: la separación por tablespace es
  suficiente para lo que pide el documento, y si la opción está disponible se
  puede proponer como extensión natural (`RESERVA` particionada por rango de
  `fecha_checkin`, con cada partición anual en su propio tablespace y las
  antiguas en modo solo lectura).

---

## FASE 7 — Generación de datos

Ver `05_carga_catalogos.sql` y `06_carga_masiva.sql`. Cuatro puntos que hay que
poder defender:

1. **Reproducibilidad.** `DBMS_RANDOM.SEED` con semilla fija en cada bloque: dos
   ejecuciones producen los mismos datos.
2. **Coherencia por construcción.** Todas las claves foráneas se toman de
   arreglos cargados desde las tablas padre con `BULK COLLECT`, nunca de un
   número aleatorio "esperando" que exista.
3. **Cero solapamientos.** Un mapa de ocupación en memoria (arreglo asociativo
   indexado por `posición_habitación × 1200 + día`) marca cada noche vendida.
   Antes de asignar una habitación se verifica que sus noches estén libres. Esto
   evita 25.000 consultas de disponibilidad contra la base y garantiza que el
   disparador de la Entrega 2 sea coherente con los datos ya cargados.
4. **Estacionalidad real.** El 55 % de los check-in se sortean entre los días de
   temporada ALTA o MEDIA. Sin ese sesgo, las consultas 1, 2, 4 y 8 mostrarían
   una línea plana y no habría nada que analizar.

Volúmenes resultantes aproximados: 60 alojamientos, 400 habitaciones,
~100 temporadas, ~18.000 tarifas, 3.000 clientes, 25.000 reservas,
~29.000 líneas de habitación, ~30.000 pagos, 40.000 servicios, ~9.000 reseñas,
125 usuarios y ~80.000 noches-habitación vendidas.

---

## FASE 8 — Justificación de las 8 consultas

| # | Pregunta de negocio | Técnica | Por qué esa técnica | Resultado esperado |
|---|---|---|---|---|
| 1 | ¿Cómo se comporta la ocupación de cada municipio a lo largo del año? | `PIVOT` | 144 filas verticales son ilegibles; la matriz municipio × mes se lee de un vistazo | 12 filas × 12 columnas; picos en jun-jul y dic |
| 2 | ¿De dónde viene el ingreso, con subtotales por municipio y por tipo? | `ROLLUP` + `GROUPING` + `GROUPING_ID` | ROLLUP da la jerarquía de un estado de resultados; CUBE añadiría combinaciones sin sentido. GROUPING distingue subtotal de NULL real | Detalle + subtotales + total general etiquetados |
| 3 | ¿Quiénes lideran **dentro** de cada municipio? | `RANK() OVER (PARTITION BY)` | `FETCH FIRST 3` daría los 3 del departamento: otra pregunta. RANK respeta empates | 3 filas por municipio (más si hay empate) |
| 4 | ¿Cómo evoluciona el ingreso mes a mes? | `LAG` | Evita auto-unir la tabla desplazada un mes | 36 filas; primer mes con NULL |
| 5 | ¿Cuánto se facturó entre dos fechas cualesquiera? | Variables de enlace | Reutiliza el plan, elimina inyección SQL, reduce el *hard parse* | Ingresos por municipio y tipo en el rango |
| 6 | ¿Cuál es el tablero mensual de ocupación? | Vista materializada | Precalcula la explosión de 25.000 estadías en ~80.000 noches | Consulta de milisegundos sobre datos agregados |
| 7 | ¿En qué dimensión concreta falla cada municipio? | `UNPIVOT` | Convierte las 5 columnas de calificación en filas: única forma de graficar y comparar dimensiones | 60 filas (12 × 5) |
| 8 | ¿Quién rinde mejor y quién depende peligrosamente de la temporada alta? | ADR, RevPAR, ventanas sin `PARTITION` | Facturar mucho ≠ rendir bien; RevPAR normaliza por tamaño de la oferta | Ranking por RevPAR + % de ingreso en temporada alta |

---

## FASE 10 — Checklist de validación

Se ejecuta con `09_validacion.sql`. Verifica en 11 bloques:

- [ ] Volúmenes mínimos (12 / 60 / 400 / 3.000 / 25.000 / 40.000) — todos `OK`
- [ ] Reservas repartidas en los tres años 2024, 2025 y 2026
- [ ] Integridad referencial: 0 huérfanos en las 7 pruebas
- [ ] Reglas de fechas: 0 violaciones (checkout ≤ checkin, servicio fuera de la estadía, etc.)
- [ ] Temporadas: 0 superpuestas, 0 días sin temporada, 1.096 filas en `DIM_TIEMPO`
- [ ] Solapamiento de habitaciones: 0 pares
- [ ] Coherencia de valores: cabecera = suma de líneas, capacidad no excedida
- [ ] Estadías multi-temporada: existen y se muestra una noche por noche
- [ ] 0 objetos inválidos
- [ ] Tablas del histórico en `TS_TURISMO_HIST`
- [ ] Vista materializada poblada y `FRESH`

---

## FASE 13 — Pruebas rápidas para la sustentación

```sql
-- ¿Cuántas estadías cruzan más de una temporada?
SELECT COUNT(*) FROM (
   SELECT rh.id_reserva_habitacion
     FROM reserva_habitacion rh
     JOIN reserva r ON r.id_reserva = rh.id_reserva
     JOIN dim_tiempo d ON d.fecha >= r.fecha_checkin AND d.fecha < r.fecha_checkout
    GROUP BY rh.id_reserva_habitacion
   HAVING COUNT(DISTINCT d.id_temporada) > 1);

-- ¿Cuántas reservas tienen más de una habitación?
SELECT habitaciones, COUNT(*) FROM (
   SELECT id_reserva, COUNT(*) AS habitaciones
     FROM reserva_habitacion GROUP BY id_reserva)
 GROUP BY habitaciones ORDER BY habitaciones;

-- Comprobar a mano el valor de una estadía concreta
SELECT d.fecha, te.tipo, t.valor_noche
  FROM reserva r
  JOIN reserva_habitacion rh ON rh.id_reserva = r.id_reserva
  JOIN habitacion h ON h.id_habitacion = rh.id_habitacion
  JOIN dim_tiempo d ON d.fecha >= r.fecha_checkin AND d.fecha < r.fecha_checkout
  JOIN temporada te ON te.id_temporada = d.id_temporada
  JOIN tarifa t ON t.id_alojamiento = h.id_alojamiento
               AND t.categoria = h.categoria
               AND t.id_temporada = d.id_temporada
 WHERE r.id_reserva = 1000 ORDER BY d.fecha;
```

---

## Auditoría de consistencia realizada

| Riesgo revisado | Resultado |
|---|---|
| FK que apuntan a la tabla equivocada | Revisadas las 17 tablas; `RESERVA_HABITACION` referencia `HABITACION`, no `ALOJAMIENTO` |
| Reserva atada a una sola temporada | Eliminado por diseño: no existe `RESERVA.id_temporada` |
| `BETWEEN` en el rango de noches | Sustituido por `>= checkin AND < checkout` en todas las consultas y en la carga |
| Temporadas con huecos o solapes | Imposible por construcción (compresión día a día) y verificado en `09` |
| `SYSDATE` dentro de un `CHECK` | Detectado en `cliente.fecha_nacimiento` y trasladado a la Entrega 2 |
| Función local PL/SQL invocada desde SQL estático | Detectado en el bloque de pagos y reescrito como procedimiento con parámetros |
| `CURRVAL` sin `NEXTVAL` previo en la sesión | Detectado en la referencia de pago; ahora el id se obtiene explícitamente antes del `INSERT` |
| `NEXT_DAY` / `TO_CHAR(fecha,'D')` dependientes del NLS | Sustituidos por aritmética de fechas sobre `DATE '1900-01-01'` |
| `TO_CHAR(fecha,'MONTH')` dependiente del NLS | Sustituido por `DECODE` explícito en español |
| `VARIABLE fecha DATE` en SQL*Plus | Corregido: `VARIABLE` no admite `DATE`; se usa `VARCHAR2` + `TO_DATE` con máscara |
| MV con refresco FAST imposible | Documentado el motivo (unión por rango + agregados) y elegido `COMPLETE ON DEMAND` |
| Índices creados de más | Omitidos a propósito los de fechas, `estado` y FK de `RESERVA`, que son el material de la Entrega 3 |
| Scripts que no corren en base limpia | `DROP` de la MV envuelto en bloque con manejo de excepción; `02_limpieza.sql` idempotente |

---

## Advertencia de ejecución

Estos scripts fueron escritos y revisados de forma cruzada contra la sintaxis de
Oracle 21c, pero **no se ejecutaron contra una instancia real** durante su
redacción. Antes de entregar: correr 01→09 en una base limpia, ajustar rutas de
datafiles y dejar constancia de la salida de `09_validacion.sql`.
