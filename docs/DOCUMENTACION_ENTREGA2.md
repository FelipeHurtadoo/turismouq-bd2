# TurismoUQ · Documentación de la Entrega 2

## FASE 1 — Alcance de la entrega

La Entrega 2 pide una capa PL/SQL sobre el modelo ya entregado:

1. `fn_valor_estadia(id_habitacion, fecha_in, fecha_out)`.
2. `sp_crear_reserva`, con excepciones propias.
3. Un cursor explícito con parámetros para un proceso masivo (la liquidación
   mensual por alojamiento).
4. Todo agrupado en un paquete.
5. Un disparador **de sentencia** sobre `TARIFA` (auditoría).
6. Un disparador **de fila** que impida solapar reservas de la misma habitación.

Como quedó anotado desde la Entrega 1 (`docs/ROADMAP_Y_SUSTENTACION.md`,
FASE 11), **nada de esto exige tocar el modelo**: solo se agregan objetos de
programa (`sql/10_pkg_turismo.sql`, `sql/11_triggers_entrega2.sql`) y un
script de pruebas (`sql/12_pruebas_entrega2.sql`). Ninguna tabla, columna,
restricción o secuencia de la Entrega 1 cambió.

### Checklist de cumplimiento, punto por punto

| Requisito del PDF | Dónde está | Evidencia (corrida real, `sql/12_pruebas_entrega2.sql`) |
|---|---|---|
| `fn_valor_estadia(id_habitacion, fecha_in, fecha_out)` | `sql/10_pkg_turismo.sql` | Bloque 1: recalculó 1.320.000 para una estadía que cruza temporadas y coincidió con el valor ya guardado por la carga masiva |
| `sp_crear_reserva` con excepciones propias (`RAISE_APPLICATION_ERROR`) para habitación no disponible, checkout ≤ checkin y capacidad excedida | mismo archivo | Bloques 2.1, 2.2, 2.3: las tres excepciones (`-20001`, `-20002`, `-20003`) se dispararon donde debían; bloque 2.4 probó el caso de éxito (reserva creada) |
| Cursor explícito con parámetros para un proceso masivo (liquidación mensual por alojamiento) | mismo archivo, `sp_liquidar_mes` con `CURSOR c_liq(p_aloj, p_anio, p_mes)` | Bloque 3: liquidó 25 reservas de un alojamiento en un mes concreto, con `OPEN`/`FETCH`/`%NOTFOUND`/`CLOSE` explícitos |
| Todo agrupado en un paquete | `PKG_TURISMO` (especificación + cuerpo) | Los tres objetos anteriores viven ahí; compila `VALID` sin errores |
| Disparador a nivel de sentencia — auditoría de `TARIFA` (quién, cuándo, valor anterior y nuevo) | `sql/11_triggers_entrega2.sql`, `trg_tarifa_auditoria` | Bloque 4: un `UPDATE` quedó registrado en `AUDITORIA_TARIFA` con usuario, fecha, valor anterior y valor nuevo |
| Disparador a nivel de fila — anti-solapamiento de reservas de la misma habitación | mismo archivo, `trg_rh_anti_solape` | Bloque 5: un `INSERT` directo a `RESERVA_HABITACION` (sin pasar por el paquete) fue rechazado con `ORA-20002`: la regla la impone la tabla, no solo el procedimiento |

---

## FASE 2 — `fn_valor_estadia`: la función más difícil del proyecto

### Qué resuelve

Dado `(id_habitacion, fecha_in, fecha_out)`, devuelve el valor total de esa
estadía en esa habitación, aplicando **la tarifa de cada temporada que la
estadía atraviese** — no una sola tarifa para todo el rango.

### Por qué es difícil

La estadía no tiene una sola tarifa: si va del 13 al 18 de diciembre y la
temporada alta empieza el 15, las noches 13-14 valen tarifa baja y las
noches 15-17 valen tarifa alta. La función tiene que cobrar **noche por
noche**, no rango por rango.

### Cómo se resolvió

Exactamente con la misma mecánica que ya se usaba en la carga de datos de la
Entrega 1 (bloque D de `06_carga_masiva.sql`, ahora encapsulada):

```sql
SELECT NVL(SUM(t.valor_noche), 0), COUNT(*)
  INTO v_valor, v_noches_tarif
  FROM habitacion h
  JOIN dim_tiempo  d ON d.fecha >= p_fecha_in AND d.fecha < p_fecha_out
  JOIN tarifa      t ON t.id_alojamiento = h.id_alojamiento
                     AND t.categoria      = h.categoria
                     AND t.id_temporada   = d.id_temporada
 WHERE h.id_habitacion = p_id_habitacion;
```

Cada fila de `DIM_TIEMPO` dentro del rango `[fecha_in, fecha_out)` ya sabe a
qué `TEMPORADA` pertenece; con `(alojamiento, categoría, temporada)` se
encuentra la tarifa exacta de esa noche. Sumar es sumar filas.

### La validación que evita el "peor bug silencioso"

Si una noche no tuviera tarifa (por ejemplo, la habitación no existe, o hay
un hueco en `DIM_TIEMPO`, o falta una fila de `TARIFA` para esa
categoría/temporada), el `JOIN` simplemente **descartaría esa noche** y la
estadía saldría más barata sin ningún aviso. Por eso la función compara
`COUNT(*)` (noches efectivamente tarifadas) contra `fecha_out - fecha_in`
(noches que debería tener la estadía) y lanza `-20005` si no coinciden. Esta
excepción ya estaba prometida en el roadmap de la Entrega 1: *"fn_valor_estadia
lanzará una excepción si el número de noches tarifadas no coincide con
fecha_out - fecha_in"*.

### Por qué `>=` / `<` y no `BETWEEN`

La noche de salida no se cobra: del 10 al 13 son tres noches, no cuatro. Es
la misma regla semiabierta que ya rige en `v_noche_vendida` desde la
Entrega 1.

---

## FASE 3 — `sp_crear_reserva`

### Firma

```sql
sp_crear_reserva(
   p_id_cliente, p_id_alojamiento, p_fecha_checkin, p_fecha_checkout,
   p_num_huespedes, p_habitaciones, p_id_reserva OUT, p_canal DEFAULT 'WEB')
```

`p_habitaciones` es una colección (`pkg_turismo.t_lista_habitaciones`, un
`TABLE OF NUMBER INDEX BY PLS_INTEGER`) porque el modelo de la Entrega 1 ya
permite que una reserva tome varias habitaciones (decisión de diseño A). Se
declaró dentro del paquete y no como `TYPE` de esquema porque el único
llamador es PL/SQL: no hace falta el privilegio `CREATE TYPE` ni un objeto
SQL adicional.

### Las tres excepciones propias exigidas

| Código | Caso | Dónde se valida |
|---|---|---|
| `-20001` | Checkout ≤ checkin | Antes de tocar nada |
| `-20002` | Habitación no disponible (no existe, inactiva, de otro alojamiento, o se solapa con una reserva activa) | Por cada habitación de la lista, antes del `INSERT` |
| `-20003` | Capacidad excedida (huéspedes > suma de capacidades de las habitaciones elegidas) | Después de recorrer toda la lista |

(Se agregó además `-20004` para el caso trivial de una lista vacía de
habitaciones; no lo exige el documento, pero dejar ese hueco sin controlar
produciría una reserva sin ninguna línea, que `09_validacion.sql` ya detecta
como anomalía en el bloque 3.)

### Por qué la disponibilidad se valida DOS veces (procedimiento y disparador)

`sp_crear_reserva` repite, antes del `INSERT`, la misma condición de
solapamiento que hace cumplir `trg_rh_anti_solape` sobre la tabla. No es
redundancia accidental: el procedimiento existe para dar un **mensaje de
negocio claro** apenas se detecta el problema (antes de escribir nada); el
disparador es la **red de seguridad** que protege el dato aunque alguien
haga un `INSERT` directo a `RESERVA_HABITACION` sin pasar por el paquete —
exactamente lo que demuestra el bloque 5 de `12_pruebas_entrega2.sql`.

### Por qué no hace `COMMIT`

La Entrega 3 exige un procedimiento transaccional que registre reserva y
pago de forma atómica, con `SAVEPOINT` y `ROLLBACK TO`. Si `sp_crear_reserva`
hiciera su propio `COMMIT`, ese procedimiento de la Entrega 3 no podría
deshacer la reserva junto con el pago fallido. Por eso el control de
transacción se deja al llamador desde ya: es la decisión que evita
reescribir este procedimiento en la Entrega 3.

### Por qué el id de la reserva se pide con `seq_reserva.NEXTVAL` y no con `RETURNING`

Ya estaba anotado desde la Entrega 1, en el propio `03_secuencias.sql`: se
necesita el id **antes** de insertar las líneas hijas de
`RESERVA_HABITACION`, así que pedirlo explícito con `NEXTVAL` es más simple
que depender de `RETURNING ... INTO` para luego usarlo en varios `INSERT`
dentro de un bucle.

---

## FASE 4 — Cursor explícito con parámetros: `sp_liquidar_mes`

### Qué resuelve

La liquidación mensual por alojamiento: cuánto se facturó, cuánto se pagó y
cuánto queda pendiente, para todas las reservas de un alojamiento cuyo
checkout cayó en un mes dado.

### Por qué el checkout y no el checkin

Un alojamiento se liquida por lo que **efectivamente se prestó**: una
reserva que hizo checkin el 29 de noviembre y checkout el 2 de diciembre se
liquida en diciembre, no en noviembre.

### El cursor

```sql
CURSOR c_liq(p_aloj NUMBER, p_anio NUMBER, p_mes NUMBER) IS
   SELECT r.id_reserva, r.fecha_checkin, r.fecha_checkout,
          r.valor_alojamiento, r.valor_servicios, r.valor_total
     FROM reserva r
    WHERE r.id_alojamiento = p_aloj
      AND r.estado IN ('CONFIRMADA', 'COMPLETADA')
      AND EXTRACT(YEAR  FROM r.fecha_checkout) = p_anio
      AND EXTRACT(MONTH FROM r.fecha_checkout) = p_mes
    ORDER BY r.fecha_checkout;
```

Es un cursor **explícito** (con `OPEN` / `FETCH` / `%NOTFOUND` / `CLOSE`, no
un cursor `FOR` implícito) y **parametrizado** (`p_aloj`, `p_anio`, `p_mes`):
se abre una vez por cada combinación alojamiento-mes que se quiera liquidar,
sin tener que reescribir la consulta. Por cada reserva se busca aparte el
total ya pagado (`PAGO.estado = 'APROBADO'`) y se acumulan los totales del
mes. No se creó una tabla nueva para guardar el resultado — decisión
consciente, ya anotada en el roadmap ("ninguna tabla" para este punto) — el
reporte se imprime con `DBMS_OUTPUT` porque es una liquidación que se
consulta, no un dato que otro proceso necesite leer después.

### Por qué puede no coincidir `PAGO` con `RESERVA.valor_total`

Por diseño de los datos de prueba (ver comentario de `06_carga_masiva.sql`,
bloque E): el pago cubre el alojamiento y, en algunos casos, es un
anticipo. La diferencia entre facturado y pagado es precisamente lo que
`sp_liquidar_mes` calcula como "saldo pendiente" — no es un error, es el
dato que la liquidación existe para mostrar.

---

## FASE 5 — Todo agrupado en un paquete: `PKG_TURISMO`

Un solo paquete (especificación + cuerpo) agrupa la función, el
procedimiento y el proceso de liquidación. Ventajas concretas que se
usaron aquí, no solo la exigencia del enunciado:

- `sp_crear_reserva` llama a `fn_valor_estadia` directamente (misma unidad
  de compilación), sin duplicar la lógica de tarifas por temporada.
- El tipo `t_lista_habitaciones` se declara una sola vez en la
  especificación y lo reutilizan tanto el paquete como cualquier bloque
  anónimo que llame a `sp_crear_reserva` (ver `12_pruebas_entrega2.sql`).
- Cambiar la implementación interna de cualquiera de los tres (por ejemplo,
  ajustar `sp_liquidar_mes` en la Entrega 3) no obliga a recompilar nada
  fuera del paquete, porque los llamadores solo dependen de la
  especificación.

---

## FASE 6 — Disparador de sentencia: auditoría de `TARIFA`

### El requisito y su contradicción aparente

El documento pide un disparador **a nivel de sentencia** que registre
**quién, cuándo, valor anterior y valor nuevo**. El problema: un disparador
de sentencia puro (`FOR ... `, sin `FOR EACH ROW`) dispara una sola vez por
`INSERT`/`UPDATE`/`DELETE`, pero **no tiene acceso a `:OLD` / `:NEW`**,
porque esos valores existen por fila, no por sentencia.

### La solución: `COMPOUND TRIGGER`

```sql
CREATE OR REPLACE TRIGGER trg_tarifa_auditoria
   FOR INSERT OR UPDATE OR DELETE ON tarifa
   COMPOUND TRIGGER
   ...
   AFTER EACH ROW IS   -- aquí SÍ hay :OLD/:NEW; solo se anota, no se inserta
   ...
   AFTER STATEMENT IS  -- aquí se hace la ÚNICA inserción en AUDITORIA_TARIFA
   ...
END;
```

Sigue siendo "a nivel de sentencia" en el sentido que importa: la sección
`AFTER STATEMENT` se ejecuta **una sola vez** por sentencia DML, sin
importar cuántas filas de `TARIFA` haya tocado. La sección `AFTER EACH ROW`
no inserta nada; solo va guardando en variables del propio bloque el último
`id_tarifa`, el último `valor_anterior`/`valor_nuevo` y un contador de
filas.

### Por qué `valor_anterior`/`valor_nuevo` son escalares y no una fila por cambio

La tabla `AUDITORIA_TARIFA` ya se diseñó así desde la Entrega 1 (columnas
escalares, más una columna `FILAS_AFECTADAS`), previendo esta solución: en
este proyecto, actualizar `TARIFA` es casi siempre una operación de una sola
fila (el administrador del alojamiento corrige un precio puntual). Si una
sentencia llegara a tocar varias filas a la vez, la auditoría de todos
modos queda completa — se sabe quién, cuándo, cuántas filas (`FILAS_AFECTADAS`)
y el último valor tocado — sin necesidad de una fila de auditoría por cada
fila de `TARIFA` modificada, que hubiera sido, otra vez, un disparador *de
fila*, no de sentencia.

---

## FASE 7 — Disparador de fila: anti-solapamiento

### El requisito

Impedir que se registre una reserva que se solape con otra de la **misma
habitación**, con la condición estándar de solapamiento de rangos:

```
nueva.checkin < existente.checkout  AND  existente.checkin < nueva.checkout
```

excluyendo las reservas en estado `CANCELADA` (regla ya anotada en la
Entrega 1).

### El problema de fondo: la tabla mutante

`RESERVA_HABITACION` no tiene fechas propias — viven en la cabecera
`RESERVA` —, así que el disparador necesita comparar la fila nueva contra
**las demás filas de su propia tabla** (`RESERVA_HABITACION`) usando las
fechas de `RESERVA` (otra tabla, sin restricción). Consultar la tabla que la
sentencia está modificando desde uno de sus propios disparadores de fila
produce `ORA-04091: table is mutating` — y esto ocurre **aunque el `INSERT`
sea de una sola fila**: Oracle considera "mutante" la tabla durante toda la
sentencia, no solo cuando inserta muchas filas a la vez.

### La solución: otra vez, `COMPOUND TRIGGER`

- `AFTER EACH ROW` solo **anota** qué fila nueva llegó (`id_reserva_habitacion`,
  `id_reserva`, `id_habitacion`) en una colección local del disparador. No
  consulta nada todavía: en ese momento la tabla sigue mutante.
- `AFTER STATEMENT` recorre esa colección y, ahí sí, para cada fila anotada
  busca en `RESERVA` las fechas de su reserva y en `RESERVA_HABITACION` si
  existe otra línea de la misma habitación cuyas fechas se solapen. Para
  ese momento la sentencia ya terminó de aplicar sus cambios y la tabla ya
  no es mutante.
- Si encuentra un cruce, `RAISE_APPLICATION_ERROR(-20002, ...)` revierte
  **toda la sentencia**, incluida la fila que parecía ya insertada: no
  queda nada a medias.

### Por qué reutiliza el código `-20002` de `sp_crear_reserva`

Es la misma regla de negocio ("habitación no disponible"), aplicada en dos
lugares distintos por razones distintas: el procedimiento la valida primero
para dar un mensaje temprano; el disparador la impone siempre, sin importar
quién escriba en la tabla. Usar el mismo código deja claro, ante cualquier
error `-20002`, que la causa es siempre la misma, sin importar si vino del
paquete o de un `INSERT` directo.

---

## FASE 8 — Qué demuestra `12_pruebas_entrega2.sql`

Un checklist ejecutable, en el mismo espíritu que `09_validacion.sql` de la
Entrega 1, sin IDs fijos (los conteos derivados varían levemente entre
corridas de `06_carga_masiva.sql`, así que cada caso de prueba busca sus
propios datos dinámicamente):

1. `fn_valor_estadia` recalculada contra una estadía real que cruza más de
   una temporada, comparada con el valor que la carga masiva ya guardó.
2. Las tres excepciones de `sp_crear_reserva` (`-20001`, `-20002`, `-20003`)
   y un caso de éxito.
3. `sp_liquidar_mes` sobre el alojamiento con más reservas cerradas en un
   mes concreto.
4. Un `UPDATE` sobre `TARIFA` y la fila que aparece en `AUDITORIA_TARIFA`.
5. Un `INSERT` directo a `RESERVA_HABITACION` (sin pasar por el paquete)
   que el disparador debe rechazar.

---

## FASE 9 — Qué NO cambió

Ninguna tabla, columna, `CHECK`, `UNIQUE`, secuencia ni índice de la
Entrega 1 se modificó. `sql/10_pkg_turismo.sql` y
`sql/11_triggers_entrega2.sql` se pueden ejecutar (y reejecutar, gracias a
`CREATE OR REPLACE`) sobre la base ya cargada, sin pasar por
`02_limpieza.sql`. Es la prueba de que diseñar bien las dos decisiones
críticas en la Entrega 1 —la tabla puente y `DIM_TIEMPO`— pagó exactamente
como se planeó.
