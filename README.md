# TurismoUQ · Bases de Datos II · Entrega 1

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
| **Entrega actual** | Entrega 1 · Modelo y consultas de análisis |

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
│   └── 09_validacion.sql
└── docs/
    ├── DOCUMENTACION_ENTREGA1.md
    ├── ROADMAP_Y_SUSTENTACION.md
    └── modelo_relacional.png
```

### Documentación

- **`docs/DOCUMENTACION_ENTREGA1.md`** — modelo conceptual y lógico, decisiones de
  diseño, diccionario de datos, justificación de las 8 consultas, tablespace y checklist.
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

### 3.1 Desde la línea de comandos

```bash
sqlplus sys/<pwd>@localhost:1521/XEPDB1 as sysdba @sql/01_tablespaces_usuario.sql
sqlplus turismo_uq/TurismoUQ_2026@localhost:1521/XEPDB1 @sql/02_limpieza.sql
sqlplus turismo_uq/TurismoUQ_2026@localhost:1521/XEPDB1 @sql/03_secuencias.sql
# ... y así sucesivamente hasta 09
```

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

Ejecuta del **02 al 09**. El script 01 no hace falta: los tablespaces y el
usuario ya existen.

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

---

## 8. Estado del proyecto

- [x] **Entrega 1** · Modelo, DDL, carga de datos, tablespace, 8 consultas y vista materializada
- [ ] **Entrega 2** · Capa PL/SQL: función, procedimiento, cursor, paquete y disparadores
- [ ] **Entrega 3** · Transacciones, concurrencia, índices y seguridad

El detalle de qué se agrega en cada entrega, y por qué el modelo actual lo
soporta sin reconstrucción, está en `docs/ROADMAP_Y_SUSTENTACION.md`.

---

## 9. Nota sobre credenciales

El script 01 contiene la contraseña del esquema en texto plano. Es aceptable
para un proyecto académico sobre una base local, pero **no es una práctica
válida en producción**: en un entorno real esa credencial iría en una variable
de entorno o en un gestor de secretos, nunca versionada en el repositorio.
