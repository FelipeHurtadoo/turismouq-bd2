# TurismoUQ · Bases de Datos II · Entregas 1, 2 y 3

Base de datos de una plataforma de reservas turísticas para los 12 municipios del
departamento del Quindío: alojamientos, habitaciones, temporadas, tarifas,
reservas, pagos, servicios complementarios y reseñas.

| | |
|---|---|
| **Asignatura** | Bases de Datos II · código 12338 · periodo 2026-2 |
| **Grupo** | 01D |
| **Docente** | Ana María Vanegas Rojas |
| **Motor** | Oracle Database XE 21c |
| **Esquema** | `TURISMO_UQ` en el PDB `XEPDB1` |
| **Entrega actual** | Entrega 3 · Transacciones, índices y seguridad (las tres entregas completas) |

### Equipo

| Integrante |
|---|
| Juan Felipe Hurtado Londoño |
| Santiago Marín Serna |
| Sebastián Agudelo Méndez |

---

## 1. Contenido del repositorio

```
turismouq-bd2/
├── README.md                     ← este archivo
├── sql/
│   ├── 01_tablespaces_usuario.sql
│   ├── 02_limpieza.sql
│   ├── 03_secuencias.sql
│   ├── 04_ddl.sql
│   ├── 05_carga_catalogos.sql
│   ├── 06_carga_masiva.sql
│   ├── 07_vistas_y_mv.sql
│   ├── 08_consultas_analisis.sql
│   ├── 09_validacion.sql
│   ├── 10_pkg_turismo.sql
│   ├── 11_triggers_entrega2.sql
│   ├── 12_pruebas_entrega2.sql
│   ├── 13_privilegios_entrega3.sql      ← Entrega 3 (como SYS)
│   ├── 14_pkg_transacciones.sql
│   ├── 15_pruebas_transacciones.sql
│   ├── 16_concurrencia.sql
│   ├── 16a_concurrencia_sesion_A.sql    ← versión manual, ventana A
│   ├── 16b_concurrencia_sesion_B.sql    ← versión manual, ventana B
│   ├── 16c_concurrencia_monitor.sql     ← versión manual, tercera ventana
│   ├── 17_indices.sql
│   ├── 18_seguridad.sql
│   └── 19_pruebas_seguridad.sql
├── docs/
│   ├── DOCUMENTACION_ENTREGA1.md
│   ├── DOCUMENTACION_ENTREGA2.md
│   ├── DOCUMENTACION_ENTREGA3.md
│   ├── TurismoUQ-Entrega1.pdf / TurismoUQ-Entrega3.pdf
│   ├── evidencia/                ← salidas reales de los scripts 15, 16, 17 y 19
│   ├── ROADMAP_Y_SUSTENTACION.md
│   └── modelo_relacional.html
└── app/                              ← interfaz web opcional (sección 10)
```

### Documentación

- **`docs/DOCUMENTACION_ENTREGA1.md`** — modelo conceptual y lógico, decisiones de
  diseño, diccionario de datos, justificación de las 8 consultas, tablespace y checklist.
- **`docs/DOCUMENTACION_ENTREGA2.md`** — la capa PL/SQL: función, procedimiento, cursor,
  paquete y los dos disparadores, con la justificación de cada decisión de diseño.
- **`docs/DOCUMENTACION_ENTREGA3.md`** — transacciones con `SAVEPOINT`, el
  experimento de concurrencia (antes/después de `FOR UPDATE`), los índices con
  sus planes y mediciones (incluido el caso donde el índice no ayuda), y la
  seguridad: matriz de roles, vistas de recepción y perfil. Incluye checklist
  punto por punto contra el PDF y preguntas probables de la sustentación.
- **`docs/ROADMAP_Y_SUSTENTACION.md`** — qué se agrega en las Entregas 2 y 3 sobre
  este mismo modelo, sin reconstruirlo, y banco de preguntas del docente con respuestas.

---

## 2. Requisitos previos

Se necesitan dos cosas: **Oracle XE 21c** corriendo y un cliente para conectarse
(**SQL Developer** o `sqlplus`).

### 2.1 Oracle XE 21c

**Opción A — Instalación nativa en Windows**

Descarga `OracleXE213_Win64.zip` desde la página de XE downloads de Oracle
(no desde la de Database downloads, que trae Enterprise Edition).

Antes de ejecutar `setup.exe`, verifica estas restricciones documentadas por
Oracle. Si no se cumplen, la instalación falla con un *rollback* al final:

- **Windows Home no está soportado.** Comprueba tu edición con `winver` o
  `wmic os get Caption`. Si dice *Home* o *Home Single Language*, usa la opción B.
- El usuario debe ser **miembro directo** del grupo Administradores. Ejecutar el
  instalador "como administrador" no basta.
- **Ninguna ruta puede tener espacios**: ni la carpeta de instalación, ni donde
  descomprimes el ZIP, ni las variables `TEMP` y `TMP`. Si tu usuario de Windows
  tiene espacios en el nombre, apunta todo a rutas como `C:\oracle`,
  `C:\XE_setup` y `C:\Temp`.
- Elimina las variables de entorno `ORACLE_HOME` y `TNS_ADMIN` si existen.

**Opción B — Docker** (obligatoria en Windows Home)

```bash
docker run -d --name oracle-xe -p 1521:1521 \
  -e ORACLE_PASSWORD=TuPasswordAqui \
  -v oracle-data:/opt/oracle/oradata \
  gvenzl/oracle-xe:21-slim
```

El parámetro `-v` conserva los datos entre reinicios. Sin él, apagar el
contenedor borra toda la base.

```bash
docker logs -f oracle-xe   # esperar: DATABASE IS READY TO USE!
docker start oracle-xe     # encender
docker stop oracle-xe      # apagar
docker ps                  # ver si está corriendo
```

El contenedor **no arranca solo** al prender el equipo.

### 2.2 SQL Developer

Descarga la versión **Windows 64-bit with JDK included**. Es un ZIP sin
instalador: descomprime en una ruta sin espacios (por ejemplo `C:\sqldeveloper`)
y ejecuta `sqldeveloper.exe`.

---

## 3. Orden estricto de ejecución

Cada script depende únicamente de objetos creados por los anteriores. Todos son
**idempotentes en base limpia** y corren de arriba a abajo.

| # | Script | Se ejecuta como | Qué hace | Tiempo |
|---|--------|-----------------|----------|--------|
| 1 | `sql/01_tablespaces_usuario.sql` | `SYS AS SYSDBA` en `XEPDB1` | 3 tablespaces, usuario `TURISMO_UQ`, cuotas y privilegios | ~10 s |
| 2 | `sql/02_limpieza.sql` | `TURISMO_UQ` | Borra objetos previos; permite re-ejecutar todo desde cero | ~5 s |
| 3 | `sql/03_secuencias.sql` | `TURISMO_UQ` | 15 secuencias (usadas como `DEFAULT ... NEXTVAL`) | ~2 s |
| 4 | `sql/04_ddl.sql` | `TURISMO_UQ` | 17 tablas con PK, FK, UNIQUE, CHECK y NOT NULL + índices iniciales | ~10 s |
| 5 | `sql/05_carga_catalogos.sql` | `TURISMO_UQ` | Municipios reales, tipos, categorías, servicios, temporadas 2024–2026 y `DIM_TIEMPO` | ~15 s |
| 6 | `sql/06_carga_masiva.sql` | `TURISMO_UQ` | 60 alojamientos, 400 habitaciones, tarifas, 3.000 clientes, 25.000 reservas, pagos, 40.000 servicios, reseñas y usuarios | **2 a 5 min** |
| 7 | `sql/07_vistas_y_mv.sql` | `TURISMO_UQ` | Vistas base de análisis + vista materializada de ocupación mensual | ~40 s |
| 8 | `sql/08_consultas_analisis.sql` | `TURISMO_UQ` | Las 8 consultas obligatorias | ~1 min |
| 9 | `sql/09_validacion.sql` | `TURISMO_UQ` | Checklist automatizado de volúmenes, integridad y objetos | ~2 min |
| 10 | `sql/10_pkg_turismo.sql` | `TURISMO_UQ` | Paquete `PKG_TURISMO`: `fn_valor_estadia`, `sp_crear_reserva`, `sp_liquidar_mes` | ~5 s |
| 11 | `sql/11_triggers_entrega2.sql` | `TURISMO_UQ` | Disparador de sentencia (auditoría de `TARIFA`) y de fila (anti-solapamiento) | ~5 s |
| 12 | `sql/12_pruebas_entrega2.sql` | `TURISMO_UQ` | Checklist de la Entrega 2: función, procedimiento, cursor y ambos disparadores | ~30 s |
| 13 | `sql/13_privilegios_entrega3.sql` | **`SYS AS SYSDBA`** en `XEPDB1` | Privilegios que faltaban para la Entrega 3 (`CREATE SESSION WITH ADMIN OPTION`, `DROP USER`, `ALTER/DROP PROFILE`, `V$SESSION`, `V$LOCK`, `V$MYSTAT`...) y `RESOURCE_LIMIT = TRUE` | ~2 s |
| 14 | `sql/14_pkg_transacciones.sql` | `TURISMO_UQ` | Paquete `PKG_TRANSACCIONES`: `sp_reservar_y_pagar` (reserva + pago atómicos con `SAVEPOINT`), `sp_registrar_pago` (pagar después o abonar) y `sp_crear_reserva_segura` (`SELECT ... FOR UPDATE`) | ~2 s |
| 15 | `sql/15_pruebas_transacciones.sql` | `TURISMO_UQ` | Demostración: caso feliz, **rollback parcial** (también por rechazo de la pasarela), rollback total, el savepoint paso a paso y pago posterior del saldo | ~5 s |
| 16 | `sql/16_concurrencia.sql` | `TURISMO_UQ` | Experimento de dos sesiones por la misma habitación: sin bloqueo (doble reserva), con `FOR UPDATE` (bloqueo y espera), `NOWAIT` y `WAIT 3` | ~30 s |
| 17 | `sql/17_indices.sql` | `TURISMO_UQ` | 3 consultas lentas con plan y medición antes/después (índice compuesto, basado en función y FK), y el caso donde el índice **no** ayuda | ~10 s |
| 18 | `sql/18_seguridad.sql` | `TURISMO_UQ` | Vistas de recepción y administración, 4 roles, perfil con límites de sesión y 5 usuarios de demostración | ~5 s |
| 19 | `sql/19_pruebas_seguridad.sql` | se conecta como cada usuario (`CONNECT`) | Comprueba lo que cada rol puede y no puede hacer; al final vuelve a `TURISMO_UQ` | ~10 s |

Los scripts 10 a 12 son la **Entrega 2** y solo agregan objetos de programa:
ningún DDL de la Entrega 1 cambia. Se pueden re-ejecutar tantas veces como
haga falta (`CREATE OR REPLACE`); no necesitan pasar por `02_limpieza.sql`.

Los scripts 13 a 19 son la **Entrega 3** y tampoco cambian ninguna tabla.
Todos son re-ejecutables: los de pruebas marcan sus reservas de demostración
con `DEMO_E3` y las borran al empezar, el de índices borra y vuelve a crear
sus índices para medir siempre el "antes" real, y el de seguridad borra y
recrea roles, perfil y usuarios.

Los archivos `16a`, `16b` y `16c` **no** forman parte de la corrida de arriba
abajo: son la versión manual del experimento de concurrencia, para hacerlo en
vivo con dos ventanas (ver sección 11).

### 3.1 Desde la línea de comandos

```bash
sqlplus sys/<pwd>@localhost:1521/XEPDB1 as sysdba @sql/01_tablespaces_usuario.sql
sqlplus turismo_uq/TurismoUQ_2026@localhost:1521/XEPDB1 @sql/02_limpieza.sql
sqlplus turismo_uq/TurismoUQ_2026@localhost:1521/XEPDB1 @sql/03_secuencias.sql
# ... y así sucesivamente hasta 12
sqlplus sys/<pwd>@localhost:1521/XEPDB1 as sysdba @sql/13_privilegios_entrega3.sql
sqlplus turismo_uq/TurismoUQ_2026@localhost:1521/XEPDB1 @sql/14_pkg_transacciones.sql
# ... y así sucesivamente hasta 19
```

Si ya tenías montada la base con las Entregas 1 y 2, **no hace falta volver a
empezar**: basta con ejecutar del 13 al 19 en orden.

### 3.2 Desde SQL Developer

Se crean dos conexiones:

| Campo | `sys_xe` | `turismo_uq` |
|---|---|---|
| Usuario | `sys` | `turismo_uq` |
| Contraseña | la de tu instalación | `TurismoUQ_2026` |
| **Rol** | **SYSDBA** | default (**sin** SYSDBA) |
| Hostname | `localhost` | `localhost` |
| Puerto | `1521` | `1521` |
| Tipo | **Nombre de servicio** (no SID) | **Nombre de servicio** |
| Servicio | `XEPDB1` | `XEPDB1` |

La conexión `turismo_uq` solo existe después de ejecutar el script 01. Los
scripts se ejecutan con **F5** (Run Script), no con Ctrl+Enter.

Del script 02 en adelante, todo se ejecuta como `TURISMO_UQ`. No trabajes como
`sys`: tiene privilegios de administración sobre toda la base y un `DROP` mal
escrito ahí no tiene vuelta atrás.

### 3.3 Antes de ejecutar el script 01: verificar la ruta de los datafiles

Conectado como `sys_xe`:

```sql
SELECT name FROM v$datafile;
```

Si la ruta que devuelve **no** es `/opt/oracle/oradata/XE/XEPDB1/`, edita las
tres cláusulas `DATAFILE` de `01_tablespaces_usuario.sql` con la ruta correcta.
Es el paso que más falla al montar el proyecto en otra máquina.

### 3.4 Ver el progreso de la carga masiva

Antes del script 06, en SQL Developer:
**Ver → Salida de DBMS → botón `+` verde → seleccionar `turismo_uq`**

Verás el avance en vivo: `reservas insertadas: 2000`, `4000`, etc.

---

## 4. Cómo saber que quedó bien

El script 09 es el checklist. Todo debe salir así:

| Bloque | Resultado esperado |
|---|---|
| 1. Volúmenes mínimos | Todas las filas en `OK` |
| 2. Reservas 2024–2026 | Los tres años con ~33 % cada uno |
| 2b. Cobertura | Los 12 municipios con alojamientos, todos en `OK` |
| 3. Integridad referencial | 7 pruebas en **0** |
| 4. Fechas y temporadas | 7 pruebas en **0** |
| 5. Solapamiento de habitaciones | **0** pares |
| 6. Coherencia de valores | 4 pruebas en **0** |
| 7. Multi-temporada | Estadías que cruzan 2 y 3 temporadas + ejemplo detallado |
| 8. Objetos | 0 inválidos |
| 9. Tablespaces | 12 tablas en `TS_TURISMO_DAT`, 6 en `TS_TURISMO_HIST` |
| 10. Restricciones | 17 PK, 17 FK, 16 UNIQUE, 141 CHECK/NOT NULL |
| 11. Vista materializada | `FRESH` y `VALID` |

Para la Entrega 3, cada script de prueba imprime `OK` o `FALLA` por línea.
Lo esperado:

| Script | Resultado esperado |
|---|---|
| 15 · Transacciones | 7 `OK`. En el bloque 2 la reserva queda `PENDIENTE` con 1 línea y **0 pagos** (rollback parcial); en el 5 se paga después y queda `CONFIRMADA` |
| 16 · Concurrencia | Escenario 1: `ANOMALÍA DEMOSTRADA` (2 reservas). Escenario 2: `V$SESSION` muestra a B bloqueada, B termina con `ORA-20002` y queda `OK` con 1 reserva. Escenario 3: `-20006` en ~0 s (`NOWAIT`) y en ~3 s (`WAIT 3`) |
| 17 · Índices | Tabla resumen: Q1, Q2 y Q3 bajan sus lecturas lógicas entre 75 % y 92 %; Q4 forzado sube lecturas y tiempo |
| 18 · Seguridad | *privilegios de recepción sobre tablas* = **0** |
| 19 · Pruebas de seguridad | 27 `OK`, ningún `FALLA` |

El detalle de cada número está en `docs/DOCUMENTACION_ENTREGA3.md`, y las salidas completas de una corrida real en `docs/evidencia/`.

Verificación rápida de que la base tiene datos:

```sql
SELECT (SELECT COUNT(*) FROM reserva)    AS reservas,
       (SELECT COUNT(*) FROM habitacion) AS habitaciones,
       (SELECT COUNT(*) FROM municipio)  AS municipios
  FROM dual;
-- esperado: 25000 · 400 · 12
```

---

## 5. Volver a empezar desde cero

Ejecuta del **02 al 19** (el 13 como `SYS`). El script 01 no hace falta: los
tablespaces y el usuario ya existen.

El 02 borra todo el esquema, de modo que la secuencia completa es reproducible
tantas veces como se quiera. Esa es la prueba de que los scripts corren de
arriba abajo en una base limpia, como exige el documento del proyecto.

Los datos se generan con `DBMS_RANDOM` con semilla fija, pero algunos conteos
derivados (líneas de habitación, pagos, reseñas) pueden variar ligeramente entre
corridas. Los volúmenes mínimos exigidos siempre se cumplen.

---

## 6. Decisiones de diseño clave

El detalle completo está en `docs/DOCUMENTACION_ENTREGA1.md`. Las dos que el
documento del proyecto exige defender, en resumen:

**A. Una reserva puede tomar varias habitaciones**

Se resuelve con la tabla puente `RESERVA_HABITACION`, que no es un simple cruce:
tiene atributos propios del vínculo (`huespedes`, `valor_noches`), lo que la
convierte en una entidad asociativa legítima.

**B. Una estadía puede atravesar varias temporadas**

`RESERVA` **no tiene** columna `id_temporada`. La temporada es una propiedad del
calendario: `TEMPORADA` define rangos disjuntos que cubren 2024–2026 sin huecos,
y `DIM_TIEMPO` asigna a cada día su temporada. El valor de una estadía se calcula
noche por noche uniendo por rango:

```sql
JOIN dim_tiempo d ON d.fecha >= r.fecha_checkin
                 AND d.fecha <  r.fecha_checkout
```

El rango es semiabierto: la noche de salida no se cobra. Del 10 al 13 son tres
noches, no cuatro. Por eso nunca se usa `BETWEEN`.

**C. Entrega 3: lo que se bloquea es la habitación**

Dos sesiones que validan disponibilidad al mismo tiempo no se ven entre sí
(lectura consistente) y venden la misma habitación dos veces; ni el
procedimiento ni el disparador de la Entrega 2 lo evitan. El recurso escaso es
la fila de `HABITACION`: `sp_crear_reserva_segura` la bloquea con
`SELECT ... FOR UPDATE` antes de validar, y la segunda sesión espera y luego
es rechazada. `sp_reservar_y_pagar` usa dos savepoints: si falla la reserva
se deshace todo; si falla el pago se deshace **solo** el pago y la reserva
queda `PENDIENTE`.

**D. Entrega 3: el alojamiento del usuario ya estaba en el modelo**

Las vistas de recepción filtran con
`SYS_CONTEXT('USERENV','SESSION_USER')` contra `USUARIO_SISTEMA.username`,
tabla que existe desde la Entrega 1 con el alojamiento de cada usuario. El
mismo `GRANT` sobre la misma vista le muestra a cada recepcionista solo su
hotel.

---

## 7. Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `ORA-01950: no privileges on tablespace` | El usuario no tiene `QUOTA` | Ejecutar el script 01 completo; otorga `QUOTA UNLIMITED` |
| `ORA-01119` al crear el tablespace | La ruta del datafile no existe | Ver sección 3.3 |
| `ORA-12541: no listener` | Oracle no está corriendo | `docker start oracle-xe` y esperar |
| `ORA-01017: invalid username/password` | Contraseña incorrecta | En Docker: `docker exec oracle-xe resetPassword <nueva>` |
| El script 06 tarda mucho | Es normal | 2 a 5 minutos; no cancelar |
| `PLS-00425` en el script 06 | Versión desactualizada del script | Usar la versión de este repositorio |
| `ORA-23319` al crear la MV | Versión desactualizada del script 07 | Usar la versión de este repositorio |
| El script 08 devuelve 11 municipios | Versión desactualizada del script 06 | Usar la versión de este repositorio |
| `sqlplus` no se reconoce | PATH sin actualizar | Reiniciar el equipo |
| `ORA-04091: table is mutating` al insertar en `RESERVA_HABITACION` | Se intentó leer esa misma tabla desde un disparador de fila normal | Ya resuelto: `trg_rh_anti_solape` es un `COMPOUND TRIGGER` que consulta en `AFTER STATEMENT`, cuando la tabla ya no es mutante |
| `ORA-06512` con código `-20002` al insertar reservas | Es el comportamiento esperado: la habitación ya está reservada en ese rango | Elegir otra habitación o fechas; ver bloque 5 de `12_pruebas_entrega2.sql` |
| `ORA-00933` en los `GRANT` del script 01 al correrlo con `sqlplus` | Versión anterior del script tenía comentarios en la misma línea después del `;` (SQL Developer los tolera, sqlplus no) | Usar la versión de este repositorio |
| `ORA-01031` o `ORA-01924` en el script 18 | No se ejecutó el 13 (falta `CREATE SESSION WITH ADMIN OPTION`, `DROP USER`...) | Ejecutar `13_privilegios_entrega3.sql` como `SYS` y repetir el 18 |
| `ORA-00942` sobre `V$SESSION` / `V$MYSTAT` al compilar en los scripts 16 o 17 | Igual: faltan los `GRANT` directos del script 13 | Ejecutar el 13 como `SYS` |
| En el script 16 el escenario 1 dice *"No se reprodujo la anomalía"* | El job de la sesión B tardó más de lo normal en arrancar | Volver a ejecutar el 16; si persiste, revisar `SELECT value FROM v$parameter WHERE name = 'job_queue_processes'` (debe ser > 0) |
| En la versión manual (16a/16b) la ventana B **no** se bloquea | Las dos hojas de SQL Developer comparten la misma sesión | Abrir la ventana B como hoja **no compartida**: Ctrl+Shift+N |
| `ORA-20009` en los scripts 15/16 | `sp_buscar_hueco` no encontró habitación libre entre mañana y el 31/12/2026 (fin del calendario cargado) | Solo pasa si se corre después de diciembre de 2026: ampliar `DIM_TIEMPO`, `TEMPORADA` y `TARIFA` |
| `ORA-02391: exceeded simultaneous SESSIONS_PER_USER limit` | Es el perfil funcionando: los usuarios de demostración tienen máximo 2 sesiones | Cerrar una de las sesiones abiertas de ese usuario |
| `ORA-02395: exceeded call limit on IO usage` | El perfil cortó una llamada de más de 200.000 lecturas lógicas | Es intencional; ver FASE 5.4 de `docs/DOCUMENTACION_ENTREGA3.md` |
| `ORA-00942` / `ORA-01031` en el script 19 | Son el resultado **esperado** de cada prueba (cada línea dice `OK` delante) | Ninguna; solo es un problema si la línea dice `FALLA` |

---

## 8. Estado del proyecto

- [x] **Entrega 1** · Modelo, DDL, carga de datos, tablespace, 8 consultas y vista materializada
- [x] **Entrega 2** · Capa PL/SQL: función, procedimiento, cursor, paquete y disparadores
- [x] **Entrega 3** · Transacciones, concurrencia, índices y seguridad

| Requisito de la Entrega 3 | Dónde |
|---|---|
| Procedimiento reserva + pago atómico con `SAVEPOINT` y rollback parcial | `pkg_transacciones.sp_reservar_y_pagar` (14) · demostración en 15 |
| Experimento de concurrencia con dos sesiones, bloqueo y `SELECT ... FOR UPDATE` antes/después | 16 (automático) · 16a/16b/16c (en vivo) |
| 3 consultas lentas, plan y medición antes/después, índice compuesto y basado en función | 17 · Q1, Q2, Q3 |
| Un caso donde el índice no ayuda, explicado | 17 · Q4 (y Q5 como caso límite) |
| 4 roles con privilegios diferenciados | 18 · `rol_recepcion`, `rol_admin_alojamiento`, `rol_gerente`, `rol_auditor` |
| Recepción accede solo por vistas | 18 · `v_recepcion_reservas`, `v_recepcion_habitaciones` · verificado en 19 |
| Perfil con límites de sesión | 18 · `perfil_turismo_operativo` |

El detalle de qué se agrega en cada entrega, y por qué el modelo actual lo
soporta sin reconstrucción, está en `docs/ROADMAP_Y_SUSTENTACION.md`.

---

## 9. Nota sobre credenciales

El script 01 contiene la contraseña del esquema en texto plano. Es aceptable
para un proyecto académico sobre una base local, pero **no es una práctica
válida en producción**: en un entorno real esa credencial iría en una variable
de entorno o en un gestor de secretos, nunca versionada en el repositorio.

Lo mismo aplica a los cinco usuarios de demostración que crea el script 18
(todos con la contraseña `Demo_UQ2026`):

| Usuario | Rol | Alojamiento |
|---|---|---|
| `recep1` | `rol_recepcion` | 1 |
| `recep2` | `rol_recepcion` | 2 |
| `admin1` | `rol_admin_alojamiento` | 1 |
| `gerente1` | `rol_gerente` | todos |
| `auditor1` | `rol_auditor` | todos |

Para conectarse como ellos en SQL Developer, crear una conexión igual a la de
`turismo_uq` cambiando usuario y contraseña. Los objetos se consultan con el
prefijo del esquema: `SELECT * FROM turismo_uq.v_recepcion_reservas;`.

---

## 10. Interfaz administrativa (opcional, fuera del alcance del documento)

El documento del proyecto es explícito: *"Ustedes no construyen la
interfaz: el entregable es la base de datos"*. La carpeta **`app/`** es, aun
así, una interfaz web (Flask + python-oracledb) para poder demostrar en vivo
que la capa PL/SQL funciona: crea reservas llamando a
`pkg_turismo.sp_crear_reserva`, liquida un mes por alojamiento, muestra las
8 consultas de análisis y el historial de `AUDITORIA_TARIFA`. No modifica
ningún script de `sql/`. Instrucciones de instalación y arranque en
`app/README.md`.

### Pasarela de pagos

La interfaz cobra con **TurismoUQ Pagos**, una pasarela en **modo de pruebas**
(como el sandbox de Wompi o PayU): *Nueva reserva → Continuar al pago* abre un
checkout con tarjeta o PSE. La respuesta de la pasarela entra a
`pkg_transacciones.sp_reservar_y_pagar`: si el banco aprueba, reserva y pago
quedan en un solo `COMMIT`; si rechaza, `ROLLBACK TO sp_antes_pago` deja la
reserva `PENDIENTE` (rollback parcial) y se puede pagar después desde el botón
**Pagos** de la barra (`sp_registrar_pago`). Tarjetas de prueba:

| Tarjeta | Resultado |
|---|---|
| `4242 4242 4242 4242` / `5555 5555 5555 4444` | Aprobada |
| `4000 0000 0000 0002` | Rechazada: fondos insuficientes |
| `4000 0000 0000 0069` / `4000 0000 0000 9987` | Rechazada: vencida / reportada |

Cualquier vencimiento futuro y CVV de 3 dígitos. En PSE, *Banco del Café*
aprueba y *Banco de la Palma* rechaza. La pasarela no acepta tarjetas reales
ni guarda el número de la tarjeta.

### Menú Entrega 3

La interfaz tiene además un menú **Entrega 3** con cuatro pantallas que llaman
a lo que crean los scripts 13 a 18:

| Pantalla | Qué muestra |
|---|---|
| Transacciones | Reserva + pago con `sp_reservar_y_pagar`: pago correcto, pago rechazado (rollback parcial: la reserva queda `PENDIENTE` sin pagos) y reserva inválida (rollback total). Botón "paso a paso" con los conteos después de cada `SAVEPOINT` |
| Concurrencia | Abre dos sesiones reales por la misma habitación y una tercera que mira `V$SESSION`. Línea de tiempo de cada evento: doble reserva sin bloqueo; con `FOR UPDATE`, B bloqueada y luego rechazada; con `NOWAIT`, B rechazada al instante |
| Índices | Plan de ejecución y lecturas lógicas antes/después de Q1–Q5, y un cuadro para medir cualquier `SELECT` que pida la docente |
| Seguridad | Se conecta como cada usuario de demostración y muestra qué permite y qué rechaza Oracle, lo que ve cada uno, el límite de 2 sesiones del perfil y la matriz de privilegios |

Detalles en `app/README.md`.

---

## 11. Pasos rápidos para el día de la sustentación

1. **Abrir Docker Desktop** y esperar a que el ícono de la ballena quede
   estable.
2. **Encender el contenedor de Oracle**: `docker start oracle-xe`, y esperar
   a ver `DATABASE IS READY TO USE!` en `docker logs -f oracle-xe` (o, si ya
   lo dejaste corriendo, verificar con `docker ps`).
3. **Abrir SQL Developer** y conectarse con la conexión `turismo_uq` (no con
   `sys`).
4. (Opcional, para tener evidencia fresca a la mano) Correr
   `sql/09_validacion.sql` y `sql/12_pruebas_entrega2.sql` — si la profesora
   pide ver algo en vivo en SQL Developer, ya está probado que corren limpio.
5. **Abrir una terminal** y encender la interfaz web:
   ```bash
   cd app
   .venv\Scripts\activate
   python app.py
   ```
   (o `docker compose up` desde `app/` si prefieres la versión en Docker).
6. **Abrir el navegador** en `http://localhost:5000`.
7. Durante la sustentación, mostrar en la interfaz (Entregas 1 y 2; para la
   Entrega 3 ver el menú **Entrega 3** y la sección 11.1):
   - **Nueva reserva** → crear una reserva real, usar "Calcular valor
     estimado" (llama a `fn_valor_estadia`) antes de confirmar.
   - **Tarifas** → editar una tarifa (dispara `trg_tarifa_auditoria`).
   - **Auditoría de tarifas** → ver la fila que acaba de quedar registrada.
   - **Liquidación mensual** → elegir un alojamiento y un mes.
   - **Consultas de análisis** → cualquiera de las 8, para mostrar PIVOT,
     ROLLUP, RANK, LAG, etc. en vivo.
8. Si piden ver el código fuente de algo puntual (la función, el
   procedimiento, los disparadores), tenerlo a la mano en SQL Developer:
   `sql/10_pkg_turismo.sql` y `sql/11_triggers_entrega2.sql`.

### 11.1 Entrega 3 en vivo

**Desde la interfaz web**, lo más visual: *Nueva reserva → Continuar al pago*
con la tarjeta `4000 0000 0000 0002` (rechazo → reserva pendiente, rollback
parcial) y luego **Pagos → Cobrar** con `4242 4242 4242 4242`. En el menú **Entrega 3**:
Transacciones → "Pago mayor al total" (rollback parcial) · Concurrencia →
"ANTES" y luego "DESPUÉS" (se ve la sesión bloqueada) · Índices → Q1 y Q4 ·
Seguridad → RECEP1 y "Abrir 3 sesiones".

**Desde SQL Developer**, los mismos resultados con los scripts:

- **Transacciones** → correr `sql/15_pruebas_transacciones.sql` (F5). Mostrar
  el bloque 2.1 (reserva `PENDIENTE`, 0 pagos: rollback parcial) y la tabla
  paso a paso del bloque 4.
- **Concurrencia, versión automática** → `sql/16_concurrencia.sql` (~30 s).
  Muestra la doble reserva sin bloqueo y, con `FOR UPDATE`, la línea de
  `V$SESSION` con la sesión B bloqueada.
- **Concurrencia, versión manual** (si piden verlo con dos ventanas):
  1. En SQL Developer abrir `16a_concurrencia_sesion_A.sql` en una hoja y
     `16b_concurrencia_sesion_B.sql` en una hoja **no compartida**
     (Ctrl+Shift+N). Opcional: `16c_concurrencia_monitor.sql` en una tercera
     hoja no compartida.
  2. A: PASO A0, luego A1 → B: PASO B1 → A: PASO A2 (salen **2** reservas).
  3. A: PASO A3, luego A4 → B: PASO B2 (**se queda esperando**) → monitor:
     ver a B bloqueada → A: PASO A5 (B se destraba con `ORA-20002`, queda
     **1** reserva) → A: PASO A6.
  Cada paso se ejecuta seleccionando el bloque y F5.
- **Índices** → `sql/17_indices.sql` y mostrar la tabla resumen. Para medir
  en vivo cualquier consulta que pida la docente:
  ```sql
  SET SERVEROUTPUT ON
  EXEC pkg_medicion.plan('SELECT ... la consulta ...');
  EXEC pkg_medicion.medir('etiqueta', 'SELECT ... la consulta ...');
  ```
  (las comillas simples dentro de la consulta se escriben dobles: `''`).
  En SQL Developer también sirve F10 (plan) y F6 (autotrace).
- **Seguridad** → `sql/19_pruebas_seguridad.sql` (F5): se conecta como cada
  usuario y muestra 27 `OK`. Para el perfil: abrir tres terminales con
  `sqlplus recep1/Demo_UQ2026@localhost:1521/XEPDB1`; la tercera es
  rechazada con `ORA-02391`. Si se usó el contenedor de Docker sin `sqlplus`
  en Windows: `docker exec -it oracle-xe sqlplus recep1/Demo_UQ2026@localhost:1521/XEPDB1`.
