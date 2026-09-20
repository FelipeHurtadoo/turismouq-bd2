# TurismoUQ · Roadmap de las Entregas 2 y 3 + Sustentación

Regla que gobierna todo el documento: **nada de lo que viene exige modificar el
modelo de la Entrega 1.** Solo se agregan objetos de programa, índices y objetos
de seguridad.

---

# FASE 11 — Entrega 2 sobre este mismo modelo

| Elemento | Qué estructura usa | Qué del modelo actual lo soporta | Qué hay que agregar | Qué NO se toca |
|---|---|---|---|---|
| `fn_valor_estadia(id_habitacion, fecha_in, fecha_out)` | `HABITACION → TARIFA`, `DIM_TIEMPO → TEMPORADA` | Todo: es el `MERGE` del bloque D de `06_carga_masiva.sql` encapsulado. `DIM_TIEMPO` cubre 2024–2026 sin huecos, así que ninguna noche queda sin tarifa | La función y su manejo de `NO_DATA_FOUND` para fechas fuera del calendario cargado | Ninguna tabla |
| `sp_crear_reserva` | `RESERVA`, `RESERVA_HABITACION`, `HABITACION` | `CHECK checkout > checkin` ya rechaza el caso trivial; el `UNIQUE(id_reserva,id_habitacion)` evita duplicados; `HABITACION.capacidad` permite validar aforo | Excepciones propias con `RAISE_APPLICATION_ERROR(-20001..-20003)`: habitación no disponible, checkout ≤ checkin, capacidad excedida | Ninguna tabla |
| Cursor explícito con parámetros | `RESERVA`, `RESERVA_HABITACION`, `PAGO`, `RESERVA_SERVICIO` | La liquidación mensual por alojamiento es agregación sobre el histórico; `ALOJAMIENTO` y `DIM_TIEMPO` dan los ejes | `CURSOR c_liq(p_aloj NUMBER, p_anio NUMBER, p_mes NUMBER)` y su bucle | Ninguna tabla |
| Paquete | Todo lo anterior | — | `PKG_TURISMO`: especificación + cuerpo agrupando función, procedimiento y cursor | Ninguna tabla |
| Disparador **de sentencia** | `TARIFA` → `AUDITORIA_TARIFA` | **La tabla `AUDITORIA_TARIFA` ya existe** con usuario, marca de tiempo, valor anterior y nuevo | El disparador `AFTER INSERT OR UPDATE OR DELETE ON tarifa`. Para capturar valor anterior/nuevo por fila hará falta un disparador compuesto (`COMPOUND TRIGGER`) o una colección de paquete | Ninguna tabla |
| Disparador **de fila** anti-solapamiento | `RESERVA_HABITACION` + `RESERVA` | Los datos cargados **ya están libres de solapamientos** (verificado en `09_validacion.sql`), así que el disparador no encontrará violaciones preexistentes | `BEFORE INSERT OR UPDATE ON reserva_habitacion FOR EACH ROW`. Ojo con la tabla mutante: hay que leer `RESERVA` (otra tabla) y `RESERVA_HABITACION`; la salida limpia es un disparador compuesto o un procedimiento invocado desde `sp_crear_reserva` | Ninguna tabla |

Detalle que conviene tener preparado: el disparador de fila debe usar la
condición de solapamiento estándar

```
nueva.checkin < existente.checkout  AND  existente.checkin < nueva.checkout
```

y excluir las reservas en estado `CANCELADA`.

---

# FASE 12 — Entrega 3 sobre este mismo modelo

| Elemento | Estructura | Soporte actual | Qué agregar |
|---|---|---|---|
| Procedimiento transaccional reserva+pago | `RESERVA`, `RESERVA_HABITACION`, `PAGO` | `PAGO` es independiente de `RESERVA` y admite varios pagos: permite confirmar el alojamiento y fallar el cobro | `sp_reservar_y_pagar` con `SAVEPOINT antes_pago`, `ROLLBACK TO antes_pago` y `COMMIT` final |
| Rollback parcial demostrable | igual | El `SAVEPOINT` deja la reserva creada y deshace solo el pago | Guion de demostración con `SELECT` intermedios |
| Concurrencia | `HABITACION`, `RESERVA_HABITACION` | Dos sesiones compitiendo por la misma habitación es un escenario natural del modelo | Sesión A y B: primero sin bloqueo (ambas insertan), luego con `SELECT ... FROM habitacion WHERE id_habitacion = :x FOR UPDATE` |
| `SELECT ... FOR UPDATE` | `HABITACION` | La habitación es el recurso escaso: bloquear esa fila serializa a los competidores | Comparar con `FOR UPDATE NOWAIT` y `WAIT 5` |
| Consulta lenta 1 → **índice compuesto** | `RESERVA` | **No existe índice sobre `(fecha_checkin, fecha_checkout)`**: hoy es *full table scan* sobre 25.000 filas | `CREATE INDEX ix_reserva_fechas ON reserva(fecha_checkin, fecha_checkout)` |
| Consulta lenta 2 → **índice basado en función** | `RESERVA` | Las consultas mensuales filtran por `TRUNC(fecha_checkin,'MM')`, y una función sobre la columna **inhabilita** cualquier índice normal | `CREATE INDEX ix_reserva_mes ON reserva(TRUNC(fecha_checkin,'MM'))` |
| Consulta lenta 3 → FK sin indexar | `RESERVA` | **`reserva(id_alojamiento)` y `reserva(id_cliente)` se dejaron sin índice a propósito** | Crear el índice y medir; explicar además el efecto secundario sobre los bloqueos de la tabla padre |
| **Caso donde el índice NO ayuda** | `RESERVA.estado` | Baja cardinalidad: `COMPLETADA` es ~70 % de las filas. Un índice B*Tree obliga a un acceso por ROWID para casi toda la tabla, más caro que el barrido completo | Crear `ix_reserva_estado`, mostrar que el optimizador lo **ignora**, forzarlo con `/*+ INDEX */` y comparar `consistent gets` |
| Roles | `USUARIO_SISTEMA` | Los cuatro roles ya son valores válidos del `CHECK`, y el ámbito por alojamiento ya está modelado | `CREATE ROLE rol_recepcion / rol_admin_alojamiento / rol_gerente / rol_auditor` + `GRANT` diferenciados |
| Recepción **solo por vistas** | vistas nuevas | `V_NOCHE_VENDIDA` y `V_INVENTARIO_NOCHE` demuestran que el patrón funciona | `V_RECEPCION_RESERVAS`, `V_RECEPCION_DISPONIBILIDAD` (filtradas por alojamiento con `SYS_CONTEXT`), y `GRANT SELECT` **solo sobre las vistas** |
| Perfil con límites de sesión | usuarios de BD | — | `CREATE PROFILE perfil_recepcion LIMIT SESSIONS_PER_USER 2 IDLE_TIME 15 CONNECT_TIME 480 ...` |

**Nada de esto obliga a modificar tablas, claves ni relaciones.**

---

# FASE 14 — Preguntas que puede hacer la profesora

## Modelado y normalización

**¿Por qué `RESERVA_HABITACION` y no una FK directa en `RESERVA`?**
Porque la relación entre reservas y habitaciones es N:M: una estadía puede tomar
tres cabañas y una habitación se usa en cientos de reservas. Además la tabla
puente tiene atributos propios (`huespedes`, `valor_noches`), lo que la convierte
en una entidad asociativa, no en un simple cruce.

**¿En qué forma normal está el modelo?**
En 3FN. Las dos redundancias existentes son deliberadas: `valor_alojamiento` y
`valor_servicios` en `RESERVA` son totales mantenidos para no recalcular ~80.000
noches en cada lectura del mostrador; `valor_total` es columna virtual, no
almacenada, así que no puede desincronizarse.

**¿`RESERVA_SERVICIO.valor_unitario` no viola 3FN frente a `SERVICIO.precio_base`?**
No. Guarda el precio **histórico** del día de la prestación. Si mañana sube el
tour del café, las facturas de 2024 no deben cambiar. Es un dato distinto, no una
copia.

**¿Por qué agregó `CATEGORIA_HABITACION` si no estaba en las 14?**
Porque la categoría es clave tanto en `HABITACION` como en `TARIFA`. Con dos
`CHECK` de texto, nada garantiza que las dos listas coincidan; con una tabla, la
integridad la impone el motor. El documento permite agregar entidades.

**¿Por qué `DIM_TIEMPO`? ¿No podía generar las fechas con `CONNECT BY`?**
Podía, pero tendría que repetir esa generación en cada consulta y en la función
de la Entrega 2, no podría indexarla ni tener estadísticas sobre ella, y sobre
todo no podría guardar a qué temporada pertenece cada día: cada consulta haría
una unión por rango contra `TEMPORADA` en vez de una igualdad.

## Temporadas y valor de la estadía

**¿Cómo cobra una estadía que empieza el 13 de diciembre y termina el 18?**
Noche por noche. Cada día de `[checkin, checkout)` se une a `DIM_TIEMPO`, que da
su temporada; con `(alojamiento, categoría, temporada)` se obtiene la tarifa de
esa noche y se suman. Del 13 al 14 se cobra tarifa baja y del 15 al 17, alta.

**¿Por qué no puso `id_temporada` en `RESERVA`?**
Porque obligaría a elegir una sola temporada para una estadía que atraviesa
varias, y cualquier elección falsearía el ingreso. La temporada es una propiedad
del calendario, no de la reserva.

**¿Qué pasa si una noche no tiene tarifa?**
El `JOIN` la descartaría en silencio y la estadía saldría más barata sin ningún
error: el peor tipo de bug. Por eso las temporadas cubren todo el rango sin
huecos y `TARIFA` tiene una fila por cada combinación
`(alojamiento, categoría, temporada)`. En la Entrega 2, `fn_valor_estadia` lanzará
una excepción si el número de noches tarifadas no coincide con
`fecha_out - fecha_in`.

**¿Por qué `>= checkin AND < checkout` y no `BETWEEN`?**
Porque la noche de salida no se cobra. Del 10 al 13 son tres noches; `BETWEEN`
daría cuatro.

## PIVOT / UNPIVOT

**¿PIVOT calcula o solo presenta?**
Agrega y presenta: exige una función de agregación. En la consulta 1, el `MAX`
opera sobre un valor único por celda, así que el efecto neto es una rotación de
filas a columnas.

**¿Por qué hay que listar los 12 meses a mano?**
Porque el conjunto de columnas del resultado tiene que conocerse en tiempo de
análisis. Para una lista dinámica se necesitaría SQL dinámico o `PIVOT XML`.

**¿UNPIVOT es exactamente lo inverso de PIVOT?**
Conceptualmente sí, pero no es reversible: `UNPIVOT` descarta las celdas nulas
salvo que se indique `INCLUDE NULLS`, y no puede reconstruir el detalle que el
`PIVOT` agregó.

## ROLLUP, CUBE, GROUPING

**¿Por qué ROLLUP y no CUBE?**
Porque las tres columnas forman una jerarquía natural (municipio > tipo >
temporada) y ROLLUP produce exactamente n+1 niveles. CUBE generaría 2ⁿ
combinaciones, entre ellas subtotales sin sentido jerárquico, multiplicando las
filas sin responder mejor la pregunta.

**¿Para qué sirve `GROUPING`?**
Devuelve 1 cuando la fila es un subtotal respecto de esa columna. Sin él es
imposible distinguir un subtotal (que muestra NULL en la columna agregada) de un
NULL real de los datos.

**¿Y `GROUPING_ID`?**
Codifica en un solo número el mapa de bits de todas las columnas agregadas, lo que
permite ordenar por nivel y filtrar un nivel concreto sin encadenar varios
`GROUPING`.

## Funciones de ventana

**¿Por qué `RANK` y no `ROW_NUMBER` ni `DENSE_RANK`?**
`ROW_NUMBER` rompería un empate de forma arbitraria y dejaría fuera a un
alojamiento con el mismo ingreso que el tercero. `RANK` respeta el empate; el
precio a pagar es que un municipio empatado puede devolver más de tres filas.
`DENSE_RANK` no saltaría puestos tras un empate, lo que aquí distorsionaría el
"top 3".

**¿Por qué no `FETCH FIRST 3 ROWS ONLY`?**
Porque devolvería los tres mejores del departamento, no tres por municipio.
`PARTITION BY` es lo que reinicia el conteo en cada municipio.

**¿Qué devuelve `LAG` en el primer mes y qué hizo con eso?**
NULL. Se deja NULL en la diferencia: poner 0 afirmaría que no hubo variación, que
es falso. El porcentaje se protege con `NULLIF` contra división por cero.

**¿Cuál es la diferencia entre una función de ventana y un `GROUP BY`?**
`GROUP BY` colapsa las filas; la función de ventana conserva cada fila y le añade
un valor calculado sobre un conjunto de filas relacionadas. Por eso la consulta 8
puede mostrar el RevPAR de cada municipio y el promedio departamental en la misma
fila sin una segunda consulta.

## Vistas materializadas

**¿En qué se diferencia de una vista normal?**
Una vista es una consulta guardada: se ejecuta cada vez. Una vista materializada
almacena el resultado en un segmento físico, ocupa espacio y puede quedar
desactualizada.

**¿Por qué `COMPLETE` y no `FAST`?**
`FAST` exige `MATERIALIZED VIEW LOG` en todas las tablas base y no admite la
unión por rango `d.fecha >= r.fecha_checkin AND d.fecha < r.fecha_checkout`, que
no es un equi-join. Se puede demostrar con `DBMS_MVIEW.EXPLAIN_MVIEW`. Además, el
recálculo completo sobre este volumen toma segundos.

**¿Por qué no `ON COMMIT`?**
Porque penalizaría cada `INSERT` de reserva en el mostrador para acelerar un
informe que se consulta unas pocas veces al día, y serializaría los `COMMIT`
sobre la misma fila agregada. El costo cae sobre la operación y el beneficio va a
la gerencia: mal reparto.

**¿Qué gana con `ENABLE QUERY REWRITE`?**
Que el optimizador pueda redirigir automáticamente hacia la MV consultas escritas
contra las tablas base, sin cambiar el código de la aplicación.

## Tablespaces

**¿Qué es un tablespace y qué relación tiene con el datafile?**
Un tablespace es la unidad lógica de almacenamiento; el datafile es el archivo
físico que lo respalda. Un tablespace puede tener varios datafiles.

**¿Por qué separó el histórico?**
Porque `RESERVA` y sus hijas concentran más del 95 % de las filas, solo crecen, y
se consultan por barridos analíticos, mientras el catálogo es pequeño y se lee por
clave. Separarlas permite respaldarlas por separado, marcarlas como solo lectura
al cerrar un periodo, contener su crecimiento y medir aparte el costo de los
índices.

**¿Le basta con `CREATE TABLE` para crear tablas ahí?**
No. Sin `QUOTA` sobre el tablespace, el usuario recibe `ORA-01950`. Por eso el
script otorga `QUOTA UNLIMITED` sobre los tres tablespaces.

## Índices (Entrega 3)

**¿Por qué no creó todos los índices desde la Entrega 1?**
Porque la Entrega 3 exige demostrar el impacto de un índice comparando el plan
antes y después. Si todo estuviera indexado, no habría nada que demostrar.

**¿Cuándo un índice NO ayuda?**
Cuando la consulta devuelve una fracción grande de la tabla. Un índice sobre
`reserva.estado`, donde `COMPLETADA` es ~70 % de las filas, obligaría a un acceso
por ROWID para casi toda la tabla; el barrido completo con lecturas
multibloque es más barato. También queda inutilizado si se aplica una función
sobre la columna filtrada, salvo que exista un índice basado en esa función.

**¿Qué es un índice compuesto y qué importa el orden de sus columnas?**
Un índice sobre varias columnas. El orden importa por el principio del prefijo
izquierdo: `(fecha_checkin, fecha_checkout)` sirve para filtrar por `fecha_checkin`
sola, pero no por `fecha_checkout` sola.

## Transacciones y concurrencia (Entrega 3)

**¿Qué es una transacción y qué garantiza?**
Una unidad atómica de trabajo con las propiedades ACID. En Oracle empieza con la
primera sentencia DML y termina con `COMMIT` o `ROLLBACK`.

**¿Qué hace un `SAVEPOINT`?**
Marca un punto intermedio: `ROLLBACK TO savepoint` deshace lo posterior y conserva
lo anterior, sin terminar la transacción. En el procedimiento reserva+pago
permite conservar la reserva y deshacer solo el cobro fallido.

**¿Qué pasa si dos sesiones reservan la misma habitación al tiempo?**
Sin bloqueo explícito, ambas leen "disponible" y ambas insertan: el modelo de
consistencia en lectura de Oracle no bloquea lectores, así que ninguna ve la fila
no confirmada de la otra. Es la anomalía que hay que demostrar.

**¿Cómo lo evita `SELECT ... FOR UPDATE`?**
Bloquea la fila de `HABITACION` desde la lectura: la segunda sesión queda en
espera hasta el `COMMIT` de la primera y entonces vuelve a evaluar la
disponibilidad con datos actualizados. Convierte una condición de carrera en una
espera serializada.

**¿Y el disparador anti-solapamiento no bastaba?**
No en concurrencia: el disparador de la sesión B no ve la fila no confirmada de la
sesión A. El disparador protege contra errores de datos; el bloqueo protege contra
la condición de carrera. Se necesitan los dos.

## Seguridad (Entrega 3)

**¿Por qué recepción accede solo por vistas?**
Por mínimo privilegio: la vista limita las filas (solo su alojamiento) y las
columnas (sin datos financieros consolidados), y desacopla el permiso del
esquema físico. Si mañana cambia una tabla, se ajusta la vista y el permiso
otorgado sigue siendo válido.

**¿Diferencia entre rol y perfil?**
El rol agrupa **privilegios** (qué puede hacer). El perfil impone **límites de
recursos y de contraseña** (cuántas sesiones, cuánto tiempo inactivo, caducidad
de la clave). Son dimensiones distintas y complementarias.

**¿Privilegio de sistema o de objeto?**
De sistema: `CREATE SESSION`, `CREATE TABLE` — habilitan una acción en la base.
De objeto: `SELECT ON v_recepcion_reservas` — habilitan una acción sobre un objeto
concreto.

## Preguntas de trampa que conviene tener listas

**"Muéstreme una reserva de cuatro habitaciones."**
El generador crea reservas de una o dos habitaciones. Se resuelve en vivo
insertando una con `sp_crear_reserva` (Entrega 2) o con un `INSERT` directo de
cuatro líneas en `RESERVA_HABITACION`: el modelo no impone ningún máximo.

**"¿Y si un cliente quiere entrar el 10 en una habitación y el 12 en otra?"**
Con este diseño serían dos reservas, porque las fechas están en la cabecera. Es una
decisión consciente: una reserva es una estadía. Mover las fechas a
`RESERVA_HABITACION` lo permitiría, a costa de complicar toda validación de
disponibilidad y de perder la noción de estadía única.

**"Borre un municipio."**
No se puede mientras tenga alojamientos: la FK lo impide y no tiene borrado en
cascada, a propósito. Solo las hijas de `RESERVA` cascadean, porque una línea de
reserva no tiene sentido sin su cabecera.
