# TurismoUQ · Documentación de la Entrega 3

## FASE 1 — Alcance de la entrega

La Entrega 3 pide cuatro cosas sobre el modelo y la capa PL/SQL ya entregados:

1. **Transacciones**: un procedimiento que registre reserva y pago de forma
   atómica, con `SAVEPOINT` y demostración de un rollback parcial.
2. **Concurrencia**: un experimento documentado con dos sesiones que intentan
   reservar la misma habitación al tiempo; mostrar el bloqueo, aplicar
   `SELECT ... FOR UPDATE` y comparar antes y después.
3. **Índices**: tres consultas lentas con su plan antes y después, índices
   creados (al menos uno compuesto y uno basado en función), medición, y un
   caso donde el índice no ayude, explicado.
4. **Seguridad**: cuatro roles (recepción, administrador de alojamiento,
   gerente y auditor) con privilegios diferenciados; recepción accede solo por
   vistas; un perfil con límites de sesión.

Como estaba anotado desde la Entrega 1 (`docs/ROADMAP_Y_SUSTENTACION.md`,
FASE 12), **nada de esto exigió tocar el modelo**: ninguna tabla, columna,
restricción o secuencia de las Entregas 1 y 2 cambió. Solo se agregaron
paquetes, vistas, índices y objetos de seguridad.

### Scripts nuevos

| # | Script | Se ejecuta como | Qué hace |
|---|---|---|---|
| 13 | `sql/13_privilegios_entrega3.sql` | `SYS AS SYSDBA` | Privilegios de sistema que faltaban (`CREATE SESSION WITH ADMIN OPTION`, `DROP USER`, `ALTER/DROP PROFILE`), acceso directo a `V$SESSION`, `V$LOCK`, `V$MYSTAT`... y `RESOURCE_LIMIT = TRUE` |
| 14 | `sql/14_pkg_transacciones.sql` | `TURISMO_UQ` | Paquete `PKG_TRANSACCIONES`: `sp_reservar_y_pagar`, `sp_registrar_pago`, `sp_crear_reserva_segura` (con `FOR UPDATE`) y `sp_buscar_hueco` |
| 15 | `sql/15_pruebas_transacciones.sql` | `TURISMO_UQ` | Demostración: caso feliz, rollback parcial (3 variantes, una de ellas el rechazo de la pasarela), rollback total, anatomía del `SAVEPOINT` y pago posterior del saldo |
| 16 | `sql/16_concurrencia.sql` | `TURISMO_UQ` | Experimento automático de concurrencia (la sesión B es un job del scheduler) |
| 16a/b/c | `sql/16a_..._sesion_A.sql`, `16b_..._sesion_B.sql`, `16c_..._monitor.sql` | `TURISMO_UQ` | El mismo experimento, para hacerlo **en vivo** con dos ventanas |
| 17 | `sql/17_indices.sql` | `TURISMO_UQ` | Paquete `PKG_MEDICION` + las consultas lentas con plan y medición antes/después |
| 18 | `sql/18_seguridad.sql` | `TURISMO_UQ` | Vistas de ámbito, 4 roles, perfil y 5 usuarios de demostración |
| 19 | `sql/19_pruebas_seguridad.sql` | (se conecta como cada usuario) | Comprueba lo que cada rol puede y no puede hacer |
| 20 | `sql/20_consultas_sustentacion.sql` | `TURISMO_UQ` | Las dos consultas pedidas para la sustentación (FASE 5b) |

### Evidencia

Las salidas **completas y sin editar** de los scripts de prueba están en
`docs/evidencia/` (`15_pruebas_transacciones.log`, `16_concurrencia.log`,
`17_indices.log`, `19_pruebas_seguridad.log`), todas de una misma sesión de
trabajo sobre la base cargada. Los fragmentos que se citan en este documento
salen literalmente de esos archivos. Los números (ids de reserva, horas,
milisegundos) cambian en cada corrida; los resultados (`OK`, la doble reserva,
el bloqueo, las lecturas lógicas) se repiten.

### Checklist de cumplimiento, punto por punto

| Requisito del PDF | Dónde está | Evidencia (`docs/evidencia/`) |
|---|---|---|
| Procedimiento que registre reserva y pago de forma **atómica** | `pkg_transacciones.sp_reservar_y_pagar` (script 14) | Script 15, bloque 1: reserva `CONFIRMADA` + 1 pago en una sola transacción |
| Con `SAVEPOINT` y **demostración de un rollback parcial** | mismo procedimiento: `SAVEPOINT sp_inicio` / `sp_antes_pago` | Script 15, bloques 2.1, 2.2 y 2.3: el pago falla, `ROLLBACK TO sp_antes_pago` deshace solo el pago, la reserva queda `PENDIENTE` con 1 línea de habitación y 0 pagos. Bloque 4: los conteos paso a paso |
| Dos sesiones reservando la misma habitación al tiempo | script 16 (automático) y 16a/16b (manual) | Escenario 1: **doble reserva** de la misma habitación (2 filas) |
| Mostrar el bloqueo | `exp_concurrencia.mostrar_bloqueos` (16) y `16c_concurrencia_monitor.sql` | `V$SESSION`: sesión B *"BLOQUEADA por la sesión A · evento enq: TX - row lock contention · espera una fila de HABITACION"*; `V$LOCK`: TX modo 6 con `BLOCK = 1` |
| Aplicar `SELECT ... FOR UPDATE` y comparar antes/después | `pkg_transacciones.sp_crear_reserva_segura` | Escenario 2: B espera 5,00 s, al `COMMIT` de A recibe `ORA-20002`; queda **1** reserva. Escenario 3: `NOWAIT` falla en 0,05 s, `WAIT 3` en 3,05 s |
| 3 consultas lentas, plan antes y después | script 17, Q1, Q2, Q3 | Planes de `DBMS_XPLAN` impresos antes y después de cada `CREATE INDEX` |
| Al menos un índice **compuesto** | `ix_reserva_aloj_checkin (id_alojamiento, fecha_checkin)` | Q1: 299 → 74 lecturas lógicas por ejecución |
| Al menos un índice **basado en función** | `ix_cliente_email_upper (UPPER(email))` | Q2: 53 → 4 lecturas lógicas por ejecución |
| Medir | `pkg_medicion.medir` (lecturas lógicas de `V$MYSTAT` + tiempo, 100 repeticiones) | Tabla resumen al final del script 17 (FASE 4) |
| Un caso donde el índice no ayude, explicado | Q4: `ix_reserva_estado`; Q5 (caso límite): `TRUNC(fecha_checkin,'MM')` | El optimizador ignora el índice; forzado con `/*+ INDEX */` empeora: 247 → 286 lecturas y 6,4 → 15,2 ms |
| Cuatro roles con privilegios diferenciados | `rol_recepcion`, `rol_admin_alojamiento`, `rol_gerente`, `rol_auditor` (script 18) | Script 19: 27 pruebas `OK` conectándose como cada usuario |
| Recepción accede solo a través de vistas | `GRANT SELECT` solo sobre `v_recepcion_reservas` y `v_recepcion_habitaciones` | Script 18: *privilegios de recepción sobre tablas = 0*. Script 19: `SELECT` a `RESERVA`, `CLIENTE`, `PAGO` → `ORA-00942` |
| Un perfil con límites de sesión | `perfil_turismo_operativo` | `SESSIONS_PER_USER 2`: la tercera conexión de `RECEP1` recibe `ORA-02391`. `LOGICAL_READS_PER_CALL`: cortó con `ORA-02395` una consulta demasiado pesada durante el desarrollo (ver FASE 5.4) |

---

## FASE 2 — Transacciones: `sp_reservar_y_pagar`

### Qué resuelve

Registrar una reserva y su pago como **una sola unidad de trabajo**. El
cliente que reserva por la web no debe quedar con un cobro sin reserva, ni el
hotel con una habitación apartada por una transacción a medio hacer.

### La estructura

```
sp_reservar_y_pagar
│
├─ SAVEPOINT sp_inicio
│    sp_crear_reserva_segura          ← bloquea la habitación (FOR UPDATE) y
│                                       llama a pkg_turismo.sp_crear_reserva
│    si falla → ROLLBACK TO sp_inicio + RAISE      (rollback TOTAL)
│
├─ SAVEPOINT sp_antes_pago
│    valida monto (-20010, -20011)
│    INSERT INTO pago ... 'APROBADO'
│    UPDATE reserva SET estado = 'CONFIRMADA'
│    si falla → ROLLBACK TO sp_antes_pago          (rollback PARCIAL)
│               UPDATE reserva SET estado = 'PENDIENTE', observaciones = motivo
│
└─ COMMIT   (salvo p_commit => FALSE)
```

### Por qué dos savepoints y no uno

Porque los dos fallos significan cosas distintas para el negocio:

- **Si falla la reserva** (habitación ocupada, capacidad excedida, fechas
  inválidas), no hay nada que conservar: se deshace todo lo que hizo el
  procedimiento y el error sube al llamador. Es el `ROLLBACK TO sp_inicio`.
  Se usa un savepoint y no un `ROLLBACK` a secas para no deshacer trabajo
  que el llamador hubiera hecho **antes** de invocar el procedimiento en la
  misma transacción.
- **Si falla el pago** (tarjeta rechazada, monto inválido, medio de pago no
  admitido), la reserva sí vale: el cliente puede pagar después en
  recepción. Se deshace **solo** el pago y la reserva queda en estado
  `PENDIENTE` con el motivo en `OBSERVACIONES`. Ese es el **rollback
  parcial** que pide el documento.

### Por qué un pago rechazado no se guarda como fila `RECHAZADO`

`PAGO.estado` admite `RECHAZADO`, pero el fallo puede venir precisamente de
que la fila de pago es inválida (referencia duplicada, medio de pago fuera del
`CHECK`, valor ≤ 0). Insertar un pago "rechazado" con esos mismos datos
volvería a fallar. El motivo queda en la reserva, que sí es válida.

### Qué errores producen el rollback parcial

| Causa | De dónde viene | Demostrado en |
|---|---|---|
| Valor del pago ≤ 0 | `RAISE_APPLICATION_ERROR(-20010)` del procedimiento | — |
| Pago mayor al total de la reserva | `RAISE_APPLICATION_ERROR(-20011)` del procedimiento | Script 15, bloque 2.1 |
| Medio de pago no admitido | `ORA-02290` del `CHECK ck_pago_medio` de la Entrega 1 | Script 15, bloque 2.2 |
| La pasarela de pagos rechazó la transacción | `RAISE_APPLICATION_ERROR(-20012)` cuando `p_respuesta_pasarela <> 'APROBADO'` | Script 15, bloque 2.3, y la interfaz web (FASE 2b) |

El bloque 2.2 importa: muestra que el rollback parcial no depende de que el
error sea "nuestro". Una restricción del modelo de la Entrega 1 dispara el
mismo mecanismo.

### `p_commit`

Por defecto el procedimiento confirma. Con `p_commit => FALSE` deja la
transacción abierta: lo usan los guiones que necesitan mostrar estados
intermedios y la prueba de seguridad del script 19, que reserva como `RECEP1`
y luego hace `ROLLBACK` para no dejar datos de prueba.

### Evidencia (script 15, bloque 4: anatomía del savepoint)

```
1) reserva creada                           | reserva 1 | líneas 1 | pagos 0
2) primer pago insertado                    | reserva 1 | líneas 1 | pagos 1
3) segundo pago insertado                   | reserva 1 | líneas 1 | pagos 2
4) ROLLBACK TO demo_antes_pago              | reserva 1 | líneas 1 | pagos 0
OK: los pagos se deshicieron y la reserva sigue en la transacción
5) ROLLBACK TO demo_inicio                  | reserva 0 | líneas 0 | pagos 0
```

Detalle para la sustentación: después de un `ROLLBACK TO` la transacción
**sigue abierta**. Un savepoint no termina la transacción, solo la recorta.
Por eso el bloque termina con un `ROLLBACK` explícito.

---

## FASE 2b — Pasarela de pagos

La interfaz web cobra con una pasarela propia, **TurismoUQ Pagos**, que
funciona en **modo de pruebas** (como el *sandbox* de Wompi, PayU o Stripe):
valida la tarjeta (algoritmo de Luhn, vencimiento, CVV) o el banco de PSE,
"consulta al banco" y responde `APROBADO` o `RECHAZADO` con un número de
transacción `TUQ-...`. Solo acepta tarjetas y bancos de prueba; no mueve
dinero ni guarda el número de la tarjeta (a la base llegan solo la respuesta,
el número de transacción y la marca con los últimos 4 dígitos).

Lo importante para la entrega: **la pasarela no decide qué se guarda**. Su
respuesta entra como parámetro a los procedimientos y es la transacción de
Oracle la que decide:

| Situación | Procedimiento | Qué hace la base |
|---|---|---|
| Reserva nueva, banco aprueba | `sp_reservar_y_pagar(..., p_respuesta_pasarela => 'APROBADO', p_referencia => 'TUQ-...')` | Reserva + pago con la referencia de la pasarela, un solo `COMMIT` |
| Reserva nueva, banco rechaza | igual, con `'RECHAZADO'` | `-20012` dentro de la fase de pago → `ROLLBACK TO sp_antes_pago`: reserva `PENDIENTE`, 0 pagos (**rollback parcial**) |
| Habitación ya tomada | igual | `-20002` en la fase de reserva → `ROLLBACK TO sp_inicio`: no queda nada y no se cobra |
| Pagar después o abonar una reserva `PENDIENTE` | `sp_registrar_pago` | `SELECT ... FOR UPDATE` sobre la reserva, `SAVEPOINT sp_pago`, pago; si el saldo llega a 0 la reserva pasa a `CONFIRMADA`. Si el banco rechaza: `ROLLBACK TO sp_pago` y la reserva sigue igual |

`sp_registrar_pago` bloquea la fila de la reserva antes de calcular el saldo
por la misma razón de la FASE 3: si dos cajeros cobraran el mismo saldo al
mismo tiempo, sin bloqueo ambos verían el saldo completo y la reserva quedaría
pagada dos veces.

Evidencia: bloques 2.3 y 5 de `docs/evidencia/15_pruebas_transacciones.log`:

```
OK: el rechazo de la pasarela produjo el rollback parcial
5.1 Abono de 100000      -> ABONO · Abono registrado. Saldo pendiente: 634000.
5.2 Saldo, rechazado     -> RECHAZADO · ORA-20012: Pasarela: pago rechazado (tarjeta bloqueada) · transacción TUQ-DEMO-RECH2.
5.3 Saldo, aprobado      -> PAGADA · Saldo cubierto. Reserva confirmada.
OK: 2 pagos aprobados, el rechazado no dejó rastro y la reserva quedó CONFIRMADA
```

Tarjetas de prueba de la interfaz: `4242 4242 4242 4242` y
`5555 5555 5555 4444` aprueban; `4000 0000 0000 0002` (fondos insuficientes),
`4000 0000 0000 0069` y `4000 0000 0000 9987` rechazan. En PSE, *Banco del
Café* aprueba y *Banco de la Palma* rechaza.

---

## FASE 3 — Concurrencia: dos sesiones, la misma habitación

### El problema

`sp_crear_reserva` (Entrega 2) valida disponibilidad con un `SELECT COUNT(*)`
y, si no hay choque, inserta. Entre la lectura y la inserción hay una
ventana. Si dos sesiones pasan por ella al tiempo:

1. A valida: libre. A inserta su reserva, **sin confirmar**.
2. B valida: libre. Oracle nunca bloquea a un lector y nunca le muestra datos
   sin confirmar de otra sesión (lectura consistente), así que B no ve la
   reserva de A.
3. B inserta. El disparador `trg_rh_anti_solape` de B tampoco ve la fila de A.
4. Ambas confirman. **La habitación quedó vendida dos veces.**

Ni la validación del procedimiento ni el disparador sirven contra esto:
protegen contra errores de datos, no contra la condición de carrera.

### Cómo se hizo el experimento reproducible (script 16)

La sesión A es la del script. La **sesión B es un job de `DBMS_SCHEDULER`**,
que Oracle ejecuta en otra sesión con su propia transacción. El job espera
3 segundos (para que A tome la habitación primero), intenta la misma reserva e
imprime con marcas de tiempo; esa salida queda en
`USER_SCHEDULER_JOB_RUN_DETAILS.OUTPUT` y A la lee al final.

Un detalle que costó encontrar: `DBMS_SCHEDULER.CREATE_JOB` hace `COMMIT`
implícito. Por eso B se lanza **antes** de que A abra su transacción. Si se
lanzara en medio, confirmaría la reserva de A y arruinaría el experimento.

Para hacerlo en vivo frente a la docente están `16a` (ventana A), `16b`
(ventana B) y `16c` (una tercera ventana que muestra el bloqueo). En SQL
Developer hay que usar **hojas no compartidas** (Ctrl+Shift+N): dos hojas
normales de la misma conexión comparten la sesión.

### Escenario 1 · ANTES: sin bloqueo

Salida literal de `docs/evidencia/16_concurrencia.log`. Las líneas `[B ...]`
las escribió el job (la otra sesión) y A las imprime al final, por eso
aparecen después del `COMMIT` aunque ocurrieron antes:

```
Habitación en disputa: 8 · 2026-11-14 a 2026-11-16 · reservas activas antes: 0
[A 18:22:24.52] reserva 25521 insertada, SIN COMMIT. A espera 8 s...
[A 18:22:30.87] V$LOCK: esta sesión tiene su bloqueo TX en modo 6 (exclusivo) · BLOCK = 0 -> nadie está esperando
[A 18:22:30.87] V$SESSION: ninguna sesión está esperando a esta.
[A 18:22:32.88] COMMIT
--- salida de la sesión B (job EXP_CONC_SIN_BLOQUEO, SUCCEEDED) ---
[B 18:22:27.62] SID 46 intenta reservar la habitación 8
[B 18:22:27.79] COMMIT: reserva 25522 creada
[B] tiempo desde el intento hasta la respuesta: 0.17 s
Reservas activas de la habitación 8 en ese rango: 2
ANOMALÍA DEMOSTRADA: la misma habitación quedó vendida dos veces
```

B no esperó nada (0,17 s) y nadie quedó bloqueado: no hubo ningún punto de
encuentro entre las dos transacciones.

### Escenario 2 · DESPUÉS: con `SELECT ... FOR UPDATE`

`sp_crear_reserva_segura` hace, **antes** de validar disponibilidad:

```sql
SELECT id_habitacion FROM habitacion WHERE id_habitacion = :1 FOR UPDATE
```

```
Habitación en disputa: 8 · 2026-11-14 a 2026-11-16
[A 18:22:33.03] FOR UPDATE sobre la habitación 8 + reserva 25523, SIN COMMIT. A espera 8 s...
[A 18:22:39.10] V$SESSION: la sesión 46 está BLOQUEADA por la sesión 283 (esta) · evento "enq: TX - row lock contention" · espera una fila de HABITACION desde hace 3 s
[A 18:22:39.11] V$LOCK: esta sesión tiene su bloqueo TX en modo 6 (exclusivo) · BLOCK = 1 -> está bloqueando a otra sesión
[A 18:22:41.11] COMMIT (libera el bloqueo)
--- salida de la sesión B (job EXP_CONC_FOR_UPDATE, SUCCEEDED) ---
[B 18:22:36.12] SID 46 intenta reservar la habitación 8
[B 18:22:41.12] RECHAZADA: ORA-20002: sp_crear_reserva: la habitación 8 no está disponible entre 2026-11-14 y 2026-11-16.
[B] tiempo desde el intento hasta la respuesta: 5.00 s
Reservas activas de la habitación 8 en ese rango: 1
OK: la competencia se serializó; solo una sesión obtuvo la habitación
```

Fíjese en las horas: B pidió la habitación a las 18:22:36.12 y recibió la
respuesta a las 18:22:41.12, exactamente cuando A hizo `COMMIT`.

### Comparación

| | Sin bloqueo (antes) | Con `FOR UPDATE` (después) |
|---|---|---|
| ¿B espera? | No (0,17 s) | Sí, hasta el `COMMIT` de A (5,00 s) |
| Lo que muestra `V$SESSION` | Nadie bloqueado | B en `enq: TX - row lock contention` sobre una fila de `HABITACION` |
| `V$LOCK` de A | TX, `BLOCK = 0` | TX, `BLOCK = 1` |
| Resultado para B | Reserva creada | `ORA-20002` (habitación no disponible) |
| Reservas de la habitación en el rango | **2 (doble venta)** | **1** |

### Por qué funciona

- La fila de `HABITACION` es el recurso escaso. Bloquearla convierte una
  condición de carrera en una **cola**: el segundo en llegar espera al primero.
- Cuando B obtiene el bloqueo, la validación de disponibilidad de
  `sp_crear_reserva` es una **sentencia nueva**. En `READ COMMITTED` (el
  nivel por defecto de Oracle) cada sentencia ve lo confirmado al momento de
  empezar, así que B ya ve la reserva que A confirmó y la rechaza.
- Se bloquea `HABITACION` y no `RESERVA_HABITACION` porque la reserva nueva
  todavía no existe: no hay fila que bloquear ahí. La habitación sí existe
  siempre.

### Decisiones de diseño

**Orden de bloqueo.** Si una reserva pide varias habitaciones, se bloquean
siempre en orden ascendente de `id_habitacion`. Sin eso, A podría tomar la 10
y pedir la 11 mientras B toma la 11 y pide la 10: interbloqueo (`ORA-00060`).

**No se reemplazó `sp_crear_reserva`.** `sp_crear_reserva_segura` la
**envuelve**: la regla de disponibilidad, capacidad y tarifa sigue en un solo
lugar (Entrega 2) y la Entrega 3 solo agrega el bloqueo.

**El bloqueo se mantiene hasta el `COMMIT` del llamador.** Mientras dura la
transacción reserva+pago, la habitación queda apartada. Es lo correcto: si el
pago tarda, nadie más puede vender esa habitación mientras tanto.

### Escenario 3 · `NOWAIT` y `WAIT n`

Un mostrador no quiere que el sistema se quede colgado si otro está
reservando la misma habitación. El parámetro `p_espera_seg` lo controla:

| `p_espera_seg` | Sentencia | Lo que pasó en la prueba |
|---|---|---|
| `NULL` | `FOR UPDATE` | Espera indefinida (escenario 2) |
| `0` | `FOR UPDATE NOWAIT` | `ORA-00054` en **0,05 s**, traducido a `-20006` |
| `3` | `FOR UPDATE WAIT 3` | `ORA-30006` a los **3,05 s**, traducido a `-20006` |

`WAIT n` no admite una variable de enlace en lugar del número, por eso esa
sentencia se arma con SQL dinámico.

---

## FASE 4 — Índices

### Metodología

- `PKG_MEDICION` (script 17) ejecuta cada consulta **100 veces**, trae
  **todas** las filas (con `DBMS_SQL`, para medir la consulta tal cual y no
  un `COUNT(*)` que el optimizador resolvería distinto) y reporta:
  - **lecturas lógicas por ejecución** (`session logical reads` de
    `V$MYSTAT`): cuántos bloques tuvo que tocar. Es la métrica principal: no
    depende de la caché ni de la carga del equipo;
  - **milisegundos por ejecución**, como dato secundario.
- El plan es el de `EXPLAIN PLAN` + `DBMS_XPLAN.DISPLAY`, con filas, costo y
  predicados (`access` = se usó para buscar; `filter` = se revisó fila por
  fila).
- Antes de medir se recolectan estadísticas (`DBMS_STATS`): sin ellas el
  optimizador decide a ciegas y la comparación no vale.
- El script borra al empezar los índices de esta entrega: cada corrida vuelve
  a medir el "antes" real.
- Las consultas usan literales, no variables de enlace, para que el plan
  mostrado por `EXPLAIN PLAN` sea exactamente el que se mide.

`PKG_MEDICION` queda en el esquema a propósito: en la sustentación permite
medir en vivo cualquier consulta que pida la docente:

```sql
SET SERVEROUTPUT ON
EXEC pkg_medicion.plan('SELECT ... ');
EXEC pkg_medicion.medir('mi consulta', 'SELECT ... ');
```

### Resultados

Valores de `docs/evidencia/17_indices.log` (una sola corrida). `RESERVA`:
~25.000 filas en 244 bloques. `CLIENTE`: 3.000 filas en ~50 bloques.

| Consulta | Índice | Lecturas lógicas / ejec. | ms / ejec. | Plan antes → después |
|---|---|---|---|---|
| **Q1** Agenda de llegadas de un alojamiento en un mes | `ix_reserva_aloj_checkin (id_alojamiento, fecha_checkin)` — **compuesto** | 299 → **74** (−75 %) | 2,10 → 0,80 | `TABLE ACCESS FULL RESERVA` → `INDEX RANGE SCAN` |
| **Q2** Buscar un cliente por correo sin distinguir mayúsculas | `ix_cliente_email_upper (UPPER(email))` — **basado en función** | 53 → **4** (−92 %) | 1,00 → 0,00 | `TABLE ACCESS FULL CLIENTE` → `INDEX RANGE SCAN` |
| **Q3** Historial de reservas de un cliente | `ix_reserva_cliente (id_cliente)` — FK sin indexar | 255 → **20** (−92 %) | 1,30 → 0,20 | `TABLE ACCESS FULL RESERVA` → `INDEX RANGE SCAN` |
| **Q4** Valor de las reservas `COMPLETADA` por alojamiento | `ix_reserva_estado (estado)` — **no ayuda** | 247 → 247 (lo ignora) · forzado: **286** | 6,40 → 6,60 · forzado: **15,20** | `FULL` → `FULL` (forzado: `INDEX RANGE SCAN`, costo 70 → 914) |
| Q4 contraste: `PENDIENTE` | el mismo `ix_reserva_estado` | 176 | 0,70 | `INDEX RANGE SCAN` |
| **Q5** (caso límite) Llegadas de un mes con `TRUNC(fecha_checkin,'MM')` | `ix_reserva_mes_checkin` — basado en función | 247 → 247 (lo ignora) · forzado: 226 | 5,90 → 6,00 · forzado: 1,20 | `FULL` → `FULL` (forzado: costo 71 → 212) |

Las lecturas lógicas son estables entre corridas; los milisegundos varían con
la carga del equipo (por eso no son la métrica principal).

### Q1 · Índice compuesto: agenda de llegadas

```sql
SELECT ... FROM reserva r JOIN cliente c ON c.id_cliente = r.id_cliente
 WHERE r.id_alojamiento = 10
   AND r.fecha_checkin >= DATE '2025-12-01' AND r.fecha_checkin < DATE '2026-01-01'
 ORDER BY r.fecha_checkin;
```

La pantalla que recepción abre cada mañana. Sin índice, barrido completo de
25.000 reservas para quedarse con 20.

**Por qué ese orden de columnas.** La columna de **igualdad**
(`id_alojamiento`) va primero y la de **rango** (`fecha_checkin`) después.
Así todas las entradas útiles quedan contiguas en el índice y se leen en un
solo tramo. Con el orden inverso, el rango de fechas recorrería las llegadas
de los 60 alojamientos y filtraría después. Y por el principio del prefijo
izquierdo, el índice también sirve para filtrar solo por `id_alojamiento`, así
que deja indexada la FK `reserva.id_alojamiento`.

Las 74 lecturas que quedan son casi todas del `TABLE ACCESS FULL` de
`CLIENTE` (50 bloques), que el optimizador prefiere a 20 búsquedas por PK
para una tabla tan pequeña.

### Q2 · Índice basado en función: cliente por correo

```sql
SELECT ... FROM cliente c WHERE UPPER(c.email) = UPPER('Cliente1500@Correo-Demo.Co');
```

Recepción busca al huésped por el correo que él dicta, escrito como venga.
**Lo interesante del caso: `CLIENTE` ya tenía un índice sobre `email`** (el
`UNIQUE uq_cliente_email` de la Entrega 1), y aun así se hacía barrido
completo. Una función aplicada sobre la columna inhabilita el índice normal:
el índice guarda `email`, no `UPPER(email)`, y no se puede buscar en él un
valor que no contiene. En el plan se ve: antes el predicado es
`filter(UPPER("C"."EMAIL")=...)`; después, `access(UPPER("EMAIL")=...)`.

El índice basado en función crea una columna virtual oculta
(`SYS_NC00012$`); por eso el script recolecta estadísticas
`FOR ALL HIDDEN COLUMNS`.

### Q3 · FK sin indexar: historial del cliente

```sql
SELECT ... FROM reserva r JOIN alojamiento a ON ...
 WHERE r.id_cliente = 1500 ORDER BY r.fecha_checkin DESC;
```

Un cliente tiene ~8 reservas entre 25.000 (0,03 % de la tabla): la consulta
más selectiva y por eso la de mayor ganancia.

Este índice tiene un **segundo efecto**, independiente del rendimiento: con
una FK sin índice, un `DELETE` o `UPDATE` de la PK en `CLIENTE` obliga a
Oracle a bloquear `RESERVA` **entera** (bloqueo TM de tabla) mientras busca
filas hijas. Con el índice, solo bloquea las filas afectadas.

### Q4 · El caso donde el índice NO ayuda: `reserva.estado`

```sql
SELECT r.id_alojamiento, COUNT(*), SUM(r.valor_total)
  FROM reserva r WHERE r.estado = 'COMPLETADA' GROUP BY r.id_alojamiento;
```

La intuición dice: "filtra por estado, entonces un índice en estado". Está
equivocada, y se demuestra en tres partes:

**a) Se crea el índice y el optimizador lo ignora.** El plan sigue siendo
`TABLE ACCESS FULL` y las lecturas no cambian (247).

**b) Se le obliga con `/*+ INDEX(r ix_reserva_estado) */` y es peor:** 286
lecturas lógicas en lugar de 247 y más del doble de tiempo (15,2 ms contra
6,4 ms). El costo estimado sube de 70 a 914.

**Por qué.** `COMPLETADA` es el **79,9 %** de las reservas. Un índice B*Tree
sirve para encontrar **pocas** filas. Para traer el 80 % de la tabla por
índice, Oracle lee la hoja del índice y salta al bloque de la tabla fila por
fila (`TABLE ACCESS BY INDEX ROWID`), visitando los mismos ~250 bloques de
`RESERVA` muchas veces. El barrido completo los lee una sola vez cada uno, y
en lecturas multibloque. El optimizador lo sabe porque `ESTADO` tiene un
**histograma de frecuencias**: conoce la proporción exacta de cada valor.

**c) Contraste: el mismo índice sí sirve para `PENDIENTE`** (1,3 %): el
optimizador lo elige solo y baja a 176 lecturas. Conclusión: **un índice no es
bueno o malo en sí mismo; depende de la selectividad del valor buscado.**

Decisión: `ix_reserva_estado` **no se conserva**. Para el reporte que motivó
crearlo no se usa, y cada `INSERT`/`UPDATE` de `RESERVA` tendría que
mantenerlo. Un índice que no se lee es costo puro de escritura y de disco.
(Si de verdad hiciera falta buscar los estados raros, la alternativa sería un
índice basado en función que solo indexe esos valores:
`CASE WHEN estado IN ('PENDIENTE','NO_SHOW') THEN estado END`; las filas con
`NULL` no entran a un B*Tree y el índice queda diminuto.)

### Q5 · Caso límite: el índice "correcto" que el optimizador no quiere

Fue el **primer candidato** para el índice basado en función y no funcionó,
así que se dejó documentado porque enseña algo distinto a Q4:

```sql
... WHERE TRUNC(r.fecha_checkin, 'MM') = DATE '2025-12-01'
```

El mes devuelve ~1.100 filas (4 % de la tabla, mucho más selectivo que Q4) y
aun así el optimizador prefiere el barrido. La razón es el **clustering
factor**: 7.459, cerca del número de **filas** (~25.000) y lejos del de
**bloques** (244). Las reservas se insertaron en orden de creación, no de
llegada, así que las llegadas de diciembre están repartidas en casi todos los
bloques de la tabla. Leerlas por índice es visitar casi los mismos bloques
que el barrido, pero uno por uno.

Se presenta como caso **límite** y no como fracaso del índice, con
honestidad: forzado, ahorra solo ~9 % de lecturas (226 contra 247) y sí ahorra
CPU (1,2 ms contra 5,9 ms) porque no evalúa `TRUNC` sobre 25.000 filas. Pero
con los bloques en disco y no en caché, ~220 lecturas de un bloque cada una
serían más lentas que ~250 bloques leídos en ráfagas, y por eso el modelo de
costo (212 contra 71) lo descarta. **Una buena selectividad no basta: si las
filas están dispersas, el índice casi no ahorra trabajo.** Tampoco se
conserva.

### Índices que quedan en el esquema

| Índice | Tabla | Tipo | Tablespace |
|---|---|---|---|
| `IX_RESERVA_ALOJ_CHECKIN` | `RESERVA` | Normal, compuesto | `TS_TURISMO_IDX` |
| `IX_CLIENTE_EMAIL_UPPER` | `CLIENTE` | Basado en función | `TS_TURISMO_IDX` |
| `IX_RESERVA_CLIENTE` | `RESERVA` | Normal | `TS_TURISMO_IDX` |

Todos en el tablespace de índices que se creó desde la Entrega 1 justamente
para poder medir aparte el costo en disco de esta entrega.

---

## FASE 5 — Seguridad

### 5.1 El vínculo usuario de BD ↔ alojamiento ya estaba en el modelo

Desde la Entrega 1, `USUARIO_SISTEMA(username, rol, id_alojamiento)` tiene el
`CHECK ck_usuario_ambito`: recepción y administrador pertenecen a **un**
alojamiento; gerente y auditor son transversales. La Entrega 3 solo conecta
eso con los usuarios reales de la base:

```sql
WHERE r.id_alojamiento = (SELECT us.id_alojamiento FROM usuario_sistema us
                           WHERE UPPER(us.username) = SYS_CONTEXT('USERENV','SESSION_USER')
                             AND us.activo = 'S')
```

Así `RECEP1` y `RECEP2` reciben **el mismo `GRANT` sobre la misma vista** y
ven filas distintas (410 reservas del alojamiento 1 contra 440 del 2). Un
usuario sin fila en `USUARIO_SISTEMA`, o inactivo, no ve nada: el valor por
defecto es "cerrado".

**Por qué `SESSION_USER` y no `CURRENT_USER`:** dentro de una vista o de un
procedimiento con derechos de definidor, `CURRENT_USER` es el dueño
(`TURISMO_UQ`). `SESSION_USER` es siempre quien inició sesión.

### 5.2 Matriz de privilegios

| Objeto | Recepción | Admin. alojamiento | Gerente | Auditor |
|---|---|---|---|---|
| `CREATE SESSION` (sistema) | ✔ | ✔ | ✔ | ✔ |
| `v_recepcion_reservas` | SELECT | SELECT (heredado) | — | — |
| `v_recepcion_habitaciones` | SELECT | SELECT (heredado) | — | — |
| `pkg_transacciones` | EXECUTE | EXECUTE (heredado) | — | — |
| `v_admin_tarifas` | — | SELECT, UPDATE(`valor_noche`) | — | — |
| `v_admin_habitaciones` | — | SELECT, UPDATE(`activa`) | — | — |
| `v_admin_ingresos_mes` | — | SELECT | — | — |
| 15 tablas de negocio, `v_noche_vendida`, `v_inventario_noche`, `mv_ocupacion_mensual` | — | — | SELECT | — |
| `pkg_turismo` (liquidación) | — | — | EXECUTE | — |
| `auditoria_tarifa`, `tarifa`, `pago`, `reserva`, `usuario_sistema` | — | — | — | SELECT |
| `cliente` (datos personales) | — | — | SELECT | **no** |
| `auditoria_tarifa` | **no** | **no** | **no** | SELECT |

Razones de cada frontera:

- **Recepción** solo lee por vistas de su alojamiento, y **escribe solo por
  el procedimiento**, nunca con `INSERT`. `pkg_transacciones` corre con los
  derechos del dueño, valida disponibilidad, bloquea la habitación y además
  verifica que el alojamiento sea el del usuario conectado (`-20020`).
- **Administrador** hereda recepción (`GRANT rol_recepcion TO
  rol_admin_alojamiento`) y además gestiona precios y habitaciones de **su**
  alojamiento. Las vistas son actualizables (una sola tabla) y tienen
  `WITH CHECK OPTION`; el `UPDATE` está otorgado **por columna**, así que
  puede cambiar `valor_noche` pero no mover una tarifa a otro alojamiento.
  Cada cambio dispara el disparador de auditoría de la Entrega 2 y queda
  registrado con `ADMIN1` como autor.
- **Gerente** ve todo el departamento para analizar (las 8 consultas, la
  vista materializada) pero no modifica nada, y **no ve la auditoría**:
  separación de funciones, quien es auditado no controla la evidencia.
- **Auditor** ve la evidencia (cambios de tarifa, pagos, reservas, quién tiene
  cuenta) en solo lectura, **sin datos personales de clientes** y sin poder
  ejecutar procesos.

### 5.3 Por qué recepción accede solo por vistas

Mínimo privilegio en dos dimensiones: la vista limita las **filas** (solo su
alojamiento) y las **columnas** (sin fecha de nacimiento ni origen del
cliente; sin totales del negocio). Además desacopla el permiso del esquema
físico: si mañana cambia una tabla, se ajusta la vista y el `GRANT` sigue
siendo válido.

Un detalle de diseño que apareció al probar: para llamar a
`sp_reservar_y_pagar`, recepción necesita declarar la lista de habitaciones,
cuyo tipo vivía en `PKG_TURISMO`. Darle `EXECUTE` sobre `PKG_TURISMO` le
habría permitido llamar `sp_crear_reserva` **sin** el control de ámbito. Se
resolvió con un `SUBTYPE t_lista_habitaciones` en `PKG_TRANSACCIONES`: el
mismo tipo, visible en el único paquete que recepción puede ejecutar.

Verificación automática (script 18): *privilegios de `ROL_RECEPCION` sobre
tablas = 0*.

### 5.4 El perfil `perfil_turismo_operativo`

| Límite | Valor | Por qué |
|---|---|---|
| `SESSIONS_PER_USER` | 2 | Un puesto de recepción no necesita más; impide compartir la cuenta entre varios equipos |
| `IDLE_TIME` | 15 min | Un equipo de mostrador desatendido no debe quedar con sesión abierta |
| `CONNECT_TIME` | 600 min | Un turno de 10 horas, como máximo |
| `LOGICAL_READS_PER_CALL` | 200.000 | Freno a una consulta desbocada |
| `FAILED_LOGIN_ATTEMPTS` / `PASSWORD_LOCK_TIME` | 5 / 15 min | Contra adivinar contraseñas |
| `PASSWORD_LIFE_TIME` / `PASSWORD_GRACE_TIME` | 90 / 7 días | Rotación de credenciales |

Los límites de recursos solo se hacen cumplir con `RESOURCE_LIMIT = TRUE`
(lo fija el script 13; en 21c ya es el valor por defecto).

**Evidencia de que funciona, con dos límites distintos:**

1. `SESSIONS_PER_USER`: con tres conexiones simultáneas como `RECEP1`, las dos
   primeras entran y la tercera recibe
   `ORA-02391: exceeded simultaneous SESSIONS_PER_USER limit`.
2. `LOGICAL_READS_PER_CALL`, **sin buscarlo**: la primera versión de
   `sp_buscar_hueco` cruzaba habitaciones × días con un `NOT EXISTS` por
   combinación (6,7 millones de lecturas lógicas). Cuando la prueba del
   script 19 la llamó como `RECEP1`, el perfil la cortó con
   `ORA-02395: exceeded call limit on IO usage`. Se reescribió (los únicos
   inicios posibles de un hueco son "mañana" o un día de checkout) y bajó a
   ~750 lecturas. Es exactamente para lo que existe ese límite.

### 5.5 Usuarios de demostración

| Usuario de BD | Rol | Alojamiento | Contraseña |
|---|---|---|---|
| `RECEP1` | `rol_recepcion` | 1 | `Demo_UQ2026` |
| `RECEP2` | `rol_recepcion` | 2 | `Demo_UQ2026` |
| `ADMIN1` | `rol_admin_alojamiento` | 1 | `Demo_UQ2026` |
| `GERENTE1` | `rol_gerente` | todos | `Demo_UQ2026` |
| `AUDITOR1` | `rol_auditor` | todos | `Demo_UQ2026` |

Cada uno corresponde a la fila de `USUARIO_SISTEMA` del mismo nombre. Como
los objetos son de `TURISMO_UQ`, se consultan con el prefijo del esquema:
`SELECT * FROM turismo_uq.v_recepcion_reservas;`.

### 5.6 Privilegios de sistema contra privilegios de objeto

- **De sistema**: habilitan una acción en la base. `CREATE SESSION` es el
  único que reciben los roles; ninguno puede crear objetos (`CREATE TABLE`
  como `RECEP1` → `ORA-01031`).
- **De objeto**: habilitan una acción sobre un objeto concreto:
  `SELECT ON v_recepcion_reservas`, `UPDATE (valor_noche) ON v_admin_tarifas`,
  `EXECUTE ON pkg_transacciones`.

La diferencia entre los dos errores que aparecen en el script 19 también es
didáctica: `ORA-00942` (*table or view does not exist*) cuando el usuario no
tiene **ningún** privilegio sobre el objeto (Oracle ni siquiera le confirma
que existe); `ORA-01031` (*insufficient privileges*) cuando lo ve pero le falta
el privilegio para esa operación.

---

## FASE 5b — Consultas pedidas para la sustentación

**1. ¿Cuál fue la habitación con más reservas en temporada alta?**

La temporada no está en la reserva sino en el calendario (decisión de diseño B
de la Entrega 1), así que "en temporada alta" se resuelve **noche por noche**:
`V_NOCHE_VENDIDA` unida a `TEMPORADA` con `tipo = 'ALTA'`, y por habitación se
cuentan las reservas distintas (`COUNT(DISTINCT id_reserva)`) que tuvieron al
menos una noche en temporada alta. Una estadía del 13 al 18 de diciembre cuenta
aunque solo sus últimas noches sean de temporada alta. Se ordena con `RANK` y
no con `ROW_NUMBER` para que un empate en el primer lugar muestre todas las
habitaciones empatadas.

Resultado en la base cargada (`docs/evidencia/20_consultas_sustentacion.log`):
la **habitación 102 de Finca La Cascada 38 (Buenavista)**, con **46 reservas**
en temporada alta (107 noches). Detrás, tres habitaciones empatadas con 44.

**2. Listado de clientes con los municipios.** La pregunta admite dos
lecturas y se resolvieron las dos:

- **2a · Clientes que han visitado más municipios**, con la lista de esos
  municipios armada con `LISTAGG` (y cuántas reservas en cada uno). Son los
  viajeros de "ruta cafetera". El primero visitó 11 de los 12 municipios.
- **2b · En cada municipio, el cliente con más reservas**, con
  `RANK() OVER (PARTITION BY municipio ...)`, la misma técnica de la consulta 3
  de la Entrega 1.

Solo cuentan reservas `CONFIRMADA` o `COMPLETADA`, el mismo criterio de las
consultas de análisis de la Entrega 1.

---

## FASE 5c — El código en pantalla

La docente pidió que en la sustentación se vea, para cada ítem, el código de
implementación y lo que observa el cliente. Cada pantalla de la interfaz de la
Entrega 3 (y el resultado del pago) tiene un panel **Ver el código**:

| Pantalla | Código que muestra | De dónde sale |
|---|---|---|
| Transacciones | `sp_reservar_y_pagar`, `sp_registrar_pago` | `USER_SOURCE` (compilado en Oracle) |
| Resultado del pago | el procedimiento que se acaba de ejecutar | `USER_SOURCE` |
| Concurrencia | `sp_crear_reserva_segura` y la validación de `sp_crear_reserva` | `USER_SOURCE` y `sql/10_pkg_turismo.sql` |
| Índices | el `CREATE INDEX`, la consulta medida y `pkg_medicion.medir` | `sql/17_indices.sql` y `USER_SOURCE` |
| Seguridad | la vista de recepción, los roles y el perfil | `sql/18_seguridad.sql` |
| Consultas de la sustentación | las tres consultas, y es el texto que se ejecuta | `sql/20_consultas_sustentacion.sql` |

---

## FASE 6 — Qué demuestran los scripts de prueba

| Script | Bloques | Resultado de la corrida |
|---|---|---|
| `15_pruebas_transacciones.sql` | Caso feliz, rollback parcial ×3 (monto, medio de pago, pasarela), rollback total, anatomía del savepoint, pago posterior del saldo | 7 `OK` |
| `16_concurrencia.sql` | Sin bloqueo, con `FOR UPDATE`, `NOWAIT`/`WAIT 3` | Anomalía demostrada → `OK` serializado → `-20006` en 0,05 s y en 3,05 s |
| `17_indices.sql` | Q1–Q5 con plan y medición | Tabla resumen de la FASE 4 |
| `19_pruebas_seguridad.sql` | 5 usuarios, 27 comprobaciones | 27 `OK`, 0 `FALLA` |

Todos son re-ejecutables. Los de transacciones y concurrencia marcan sus
reservas con `DEMO_E3` en `OBSERVACIONES` y las borran al empezar (y el 16
también al terminar): el histórico cargado no se toca.

---

## FASE 7 — Qué NO cambió

- Ninguna tabla, columna, restricción ni secuencia de la Entrega 1.
- `PKG_TURISMO` y los dos disparadores de la Entrega 2 siguen idénticos.
  `PKG_TRANSACCIONES` los compone; no los reemplaza.
- Objetos nuevos: paquetes `PKG_TRANSACCIONES` (con `sp_registrar_pago` para la pasarela) y `PKG_MEDICION`; vistas
  `V_RECEPCION_RESERVAS`, `V_RECEPCION_HABITACIONES`, `V_ADMIN_TARIFAS`,
  `V_ADMIN_HABITACIONES`, `V_ADMIN_INGRESOS_MES`; índices
  `IX_RESERVA_ALOJ_CHECKIN`, `IX_CLIENTE_EMAIL_UPPER`, `IX_RESERVA_CLIENTE`;
  4 roles, 1 perfil y 5 usuarios.
- `02_limpieza.sql` borra los paquetes, vistas e índices nuevos junto con el
  resto del esquema. Roles, perfil y usuarios no son objetos del esquema y
  sobreviven; `18_seguridad.sql` los borra y recrea, así que basta volver a
  correrlo.

---

## FASE 8 — Preguntas probables de la sustentación

**¿Qué diferencia hay entre `ROLLBACK` y `ROLLBACK TO SAVEPOINT`?**
`ROLLBACK` deshace toda la transacción y la termina. `ROLLBACK TO` deshace
solo lo posterior al savepoint, libera los bloqueos tomados después de él, y
la transacción **sigue abierta**.

**¿Por qué la reserva queda `PENDIENTE` y no se borra cuando el pago falla?**
Porque la reserva es válida: lo que falló es el cobro. El cliente puede pagar
después; borrarla le quitaría la habitación por un problema de la tarjeta.

**¿Por qué el disparador anti-solape no evitó la doble reserva?**
Porque corre dentro de la transacción de B y B no ve lo que A no ha
confirmado. Un disparador protege la integridad de los datos visibles; no
coordina transacciones concurrentes. Para eso está el bloqueo.

**¿Por qué no usar `SERIALIZABLE`?**
En Oracle, `SERIALIZABLE` no bloquea: hace que B falle con `ORA-08177` al
intentar modificar algo que cambió desde que empezó su transacción. Aquí
ni eso sirve, porque A y B insertan filas **distintas** (cada uno su
reserva): no hay conflicto de escritura que detectar. El `FOR UPDATE` crea
el punto de encuentro que falta.

**¿Qué es el clustering factor?**
Cuántas veces cambia de bloque de tabla un recorrido completo del índice en
orden. Cerca del número de bloques: las filas con valores cercanos están
juntas y el índice rinde. Cerca del número de filas: están dispersas y cada
fila es un bloque distinto. Explica Q5.

**¿Un índice siempre acelera las consultas?**
No (Q4 y Q5). Y siempre encarece las escrituras: cada `INSERT`, `DELETE` y
cada `UPDATE` de la columna indexada debe mantener el índice. Por eso los
índices que no se usan se borraron.

**¿Diferencia entre rol y perfil?**
El rol agrupa **privilegios** (qué puede hacer). El perfil impone **límites
de recursos y de contraseña** (cuánto y por cuánto tiempo). Un usuario tiene
un perfil y uno o varios roles.

**¿Cómo sabe la vista cuál es el alojamiento del usuario conectado?**
Por `SYS_CONTEXT('USERENV','SESSION_USER')` cruzado con
`USUARIO_SISTEMA.username`, que existe desde la Entrega 1.
