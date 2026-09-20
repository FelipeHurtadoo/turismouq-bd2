# TurismoUQ · Bases de Datos II · Entrega 1

Base de datos de la plataforma de reservas turísticas del Quindío.
Motor: **Oracle Database XE 21c** (PDB `XEPDB1`), esquema `TURISMO_UQ`.

## Orden estricto de ejecución

Cada script depende únicamente de objetos creados por los anteriores.
Todos son **idempotentes en base limpia** y corren de arriba a abajo.

| # | Script | Se ejecuta como | Qué hace |
|---|--------|-----------------|----------|
| 1 | `sql/01_tablespaces_usuario.sql` | `SYS AS SYSDBA` en `XEPDB1` | Crea 3 tablespaces, el usuario `TURISMO_UQ`, cuotas y privilegios |
| 2 | `sql/02_limpieza.sql` | `TURISMO_UQ` | Borra objetos previos (permite re-ejecutar todo desde cero) |
| 3 | `sql/03_secuencias.sql` | `TURISMO_UQ` | 16 secuencias (usadas como `DEFAULT ... NEXTVAL`) |
| 4 | `sql/04_ddl.sql` | `TURISMO_UQ` | 17 tablas, PK/FK/UNIQUE/CHECK/NOT NULL, índices iniciales |
| 5 | `sql/05_carga_catalogos.sql` | `TURISMO_UQ` | Municipios reales, tipos, categorías, servicios, temporadas 2024–2026 y `DIM_TIEMPO` |
| 6 | `sql/06_carga_masiva.sql` | `TURISMO_UQ` | 60 alojamientos, 400 habitaciones, tarifas, 3.000 clientes, 25.000 reservas, pagos, 40.000 servicios, reseñas, usuarios |
| 7 | `sql/07_vistas_y_mv.sql` | `TURISMO_UQ` | Vista base de análisis + vista materializada de ocupación mensual |
| 8 | `sql/08_consultas_analisis.sql` | `TURISMO_UQ` | Las 8 consultas obligatorias |
| 9 | `sql/09_validacion.sql` | `TURISMO_UQ` | Checklist automatizado de volúmenes, integridad y objetos |

```bash
sqlplus sys/<pwd>@localhost:1521/XEPDB1 as sysdba @sql/01_tablespaces_usuario.sql
sqlplus turismo_uq/TurismoUQ_2026@localhost:1521/XEPDB1 @sql/02_limpieza.sql
# ... y así sucesivamente hasta 09
```

Tiempo aproximado del script 06 en XE 21c sobre disco SSD: **2 a 5 minutos**.

## Documentación

- `docs/DOCUMENTACION_ENTREGA1.md` — modelo conceptual y lógico, decisiones de diseño,
  diccionario de datos, justificación de las 8 consultas, tablespace, checklist.
- `docs/ROADMAP_Y_SUSTENTACION.md` — qué se agrega en Entrega 2 y 3 sobre este mismo
  modelo (sin reconstruirlo) y banco de preguntas del docente con respuestas.

## Advertencia honesta

Estos scripts **no han podido ser ejecutados** contra una instancia Oracle real durante su
redacción. Están escritos contra la sintaxis de Oracle 21c y revisados de forma cruzada,
pero el paso obligatorio antes de entregar es correrlos de 01 a 09 sobre una base limpia y
ajustar cualquier detalle de entorno (rutas de datafiles, nombre del PDB, memoria PGA).
