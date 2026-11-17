# TurismoUQ · Guion del video de sustentación (Entrega 3)

Guion para grabar entre los **tres integrantes**. Cubre los ítems que va a
calificar la docente, y para cada uno dice **qué código mostrar** y **qué
mostrar en la interfaz** (lo que vería el cliente), como ella pidió.

| Integrante | Parte | Tiempo aprox. |
|---|---|---|
| **Juan Felipe Hurtado** | 1. Presentación y repositorio · 2. Transacción reserva + pago (savepoint y rollback) | 5 min |
| **Santiago Marín** | 3. Concurrencia · 4. Tres consultas lentas, plan y tiempos, índice compuesto y basado en función | 6 min |
| **Sebastián Agudelo** | 5. Índice que no ayuda · 6. Las dos consultas nuevas · 7. Valor del proyecto y cierre | 6 min |

Total: unos **17 minutos**. Cada uno habla en su parte y el último le pasa la
palabra al siguiente; así queda claro en el video que hablan todos.

Cómo leer el guion: **🖥 Interfaz** es lo que se muestra en el navegador,
**💻 Código** es lo que se muestra en el panel *Ver el código* de esa misma
pantalla (o en SQL Developer, si se indica), y el texto entre comillas es lo
que dice el integrante. No hace falta decirlo palabra por palabra.

---

## Antes de grabar (una sola persona, 10 minutos)

1. Abrir **Docker Desktop** y esperar a que diga *Engine running*. Luego:
   ```bash
   docker start oracle-xe
   ```
   y esperar `DATABASE IS READY TO USE!` en `docker logs -f oracle-xe`
   (Ctrl+C para salir).
2. Encender la interfaz:
   ```bash
   cd app
   .venv\Scripts\activate
   python app.py
   ```
   Abrir `http://localhost:5000` con el zoom del navegador al **110 %**.
3. Abrir **SQL Developer** con la conexión `turismo_uq` (para la parte del
   repositorio y por si piden algo en vivo).
4. **Pasada de prueba sin grabar:** recorrer una vez todo el guion. El
   primer clic de cada pantalla es más lento.
5. Para la parte 2 tener a la mano un documento de cliente que exista.
   Sirve cualquiera de *Operación → Reservas recientes* (o crear uno nuevo
   en el mismo formulario).
6. Silenciar notificaciones. Grabar con OBS, Zoom/Meet (grabando la
   reunión con los tres) o `Win + Alt + R`.

> Si graban por separado, cada integrante graba su parte con estos mismos
> pasos y luego se unen los videos en orden.

---

## Parte 1 · Juan Felipe — Presentación y repositorio (1,5 min)

🖥 **Interfaz:** portada `http://localhost:5000`.

> "Buenas, profesora. Somos el grupo 01D: Juan Felipe Hurtado, Santiago
> Marín y Sebastián Agudelo, y vamos a sustentar la Entrega 3 de TurismoUQ,
> la plataforma de reservas turísticas de los 12 municipios del Quindío, en
> Oracle XE 21c.
>
> Un principio que seguimos en todo el proyecto: la lógica vive en la base de
> datos. La interfaz web que van a ver solo llama a los paquetes PL/SQL; cada
> pantalla tiene un botón *Ver el código* que muestra el código que está
> compilado en Oracle en ese momento."

💻 **GitHub o el explorador de archivos:** carpeta `sql/`.

> "Este es el repositorio. Los scripts están numerados en el orden en que se
> ejecutan, del 01 al 20: del 01 al 09 la Entrega 1, del 10 al 12 la Entrega 2,
> del 13 al 19 la Entrega 3 y el 20 con las dos consultas que nos pidió para
> hoy. Todos corren de arriba abajo en una base limpia; lo comprobamos
> creando una base nueva desde cero. En `docs/` están el PDF con el modelo y
> las decisiones de diseño, y en `docs/evidencia/` la salida completa de las
> pruebas."

---

## Parte 2 · Juan Felipe — Transacción reserva + pago, savepoint y rollback (3,5 min)

### 2.1 El código

🖥 **Interfaz:** menú **Entrega 3 → Transacciones y savepoints**.
💻 **Código:** abrir *Ver el código · pkg_transacciones.sp_reservar_y_pagar*.

> "El procedimiento `sp_reservar_y_pagar` registra la reserva y el pago como
> una sola transacción. Tiene dos savepoints.
>
> Primero, `SAVEPOINT sp_inicio` y se crea la reserva bloqueando la
> habitación. Si la reserva falla —habitación ocupada, más huéspedes de los
> que caben— hacemos `ROLLBACK TO sp_inicio`: no queda nada y el error sube.
>
> Después, `SAVEPOINT sp_antes_pago` y se inserta el pago. Si el pago falla
> —el banco lo rechaza, el monto supera el total, el medio de pago no es
> válido— hacemos `ROLLBACK TO sp_antes_pago`. Eso es un **rollback
> parcial**: se deshace solo el pago, la reserva se conserva en estado
> PENDIENTE y el cliente puede pagar después. Al final, un solo `COMMIT`."

### 2.2 Lo que ve el cliente: la pasarela de pagos

🖥 **Interfaz:** **Operación → Nueva reserva**.

1. Buscar el cliente por documento, elegir alojamiento, fechas (unos días
   adelante), una habitación y clic en **Calcular valor estimado**.
   > "El valor lo calcula `fn_valor_estadia` noche por noche, con la tarifa de
   > cada temporada que atraviese la estadía."
2. Clic en **Continuar al pago**.
   > "Esta es nuestra pasarela de pagos, en modo de pruebas: funciona como el
   > sandbox de Wompi o PayU, valida la tarjeta y responde aprobado o
   > rechazado. No mueve dinero ni guarda el número de la tarjeta."
3. En *Modo de pruebas*, clic en la fila **4000 0000 0000 0002** (fondos
   insuficientes) y **Pagar**.
4. En el resultado:
   > "El banco rechazó el pago. Miren el estado: la reserva quedó
   > **PENDIENTE** con **cero pagos**. Eso es el rollback parcial: la base hizo
   > `ROLLBACK TO sp_antes_pago`. La habitación sigue apartada."

   💻 Abrir *Ver el código* en esa misma pantalla y señalar la línea
   `ROLLBACK TO SAVEPOINT sp_antes_pago`.
5. Clic en **Intentar el pago de nuevo**, fila **4242 4242 4242 4242**,
   **Pagar**.
   > "Ahora con una tarjeta aprobada. Este pago lo registra
   > `sp_registrar_pago`, que bloquea la reserva con `FOR UPDATE` para que dos
   > cajeros no cobren el mismo saldo. La reserva pasó a **CONFIRMADA** y en
   > la tabla PAGO está el pago con la referencia de la pasarela."

### 2.3 El rollback paso a paso

🖥 **Interfaz:** **Entrega 3 → Transacciones** → botón **Ejecutar paso a paso**.

> "Esta tabla muestra el savepoint por dentro: después de crear la reserva
> hay una reserva y cero pagos; insertamos dos pagos; con `ROLLBACK TO
> demo_antes_pago` los pagos vuelven a cero pero la reserva sigue. Y con
> `ROLLBACK TO demo_inicio` desaparece todo. Un savepoint no termina la
> transacción: solo la recorta."

Opcional: botón **Reserva inválida (-20003)** → "rollback total: antes y
después hay el mismo número de reservas".

> "Le paso la palabra a Santiago, que va a mostrar la concurrencia."

---

## Parte 3 · Santiago — Concurrencia (3 min)

🖥 **Interfaz:** **Entrega 3 → Concurrencia y bloqueos**.
💻 **Código:** *Ver el código · pkg_transacciones.sp_crear_reserva_segura*.

> "El problema: dos recepcionistas reservan la misma habitación para las
> mismas fechas al mismo tiempo. Al presionar el botón, la aplicación abre
> dos sesiones reales de Oracle, A y B, y una tercera que mira la vista
> `V$SESSION`."

1. Clic en **ANTES · sin bloqueo** y esperar unos 5 segundos.
   > "Sin bloqueo, A reserva y no confirma. B valida la disponibilidad, pero
   > por la lectura consistente de Oracle no ve lo que A no ha confirmado, así
   > que la habitación le parece libre. Resultado: **la misma habitación quedó
   > vendida dos veces**. Ni la validación del procedimiento ni el disparador
   > anti-solapamiento de la Entrega 2 lo evitan, porque los dos corren dentro
   > de la transacción de B."
2. Clic en **DESPUÉS · con SELECT ... FOR UPDATE**.
   > "Ahora usamos `sp_crear_reserva_segura`."

   💻 Señalar en el código el `SELECT id_habitacion FROM habitacion WHERE
   id_habitacion = :1 FOR UPDATE`.
   > "Antes de validar, bloquea la fila de la habitación. Miren el monitor: la
   > sesión B aparece **bloqueada por la sesión A** con el evento *enq: TX - row
   > lock contention*, esperando una fila de HABITACION. Cuando A hace COMMIT,
   > B continúa, vuelve a validar, ya ve la reserva de A y es rechazada con
   > `ORA-20002`. Ahora hay **una sola reserva**. Además bloqueamos siempre en
   > orden de id para evitar interbloqueos."
3. Clic en **Variante · FOR UPDATE NOWAIT**.
   > "Y con NOWAIT, B no se queda esperando: falla al instante con un mensaje
   > claro para el recepcionista."

---

## Parte 4 · Santiago — Tres consultas lentas e índices (3 min)

🖥 **Interfaz:** **Entrega 3 → Índices y planes de ejecución**.

> "Medimos con el paquete `pkg_medicion`: el plan sale de `EXPLAIN PLAN` y la
> medición ejecuta la consulta 50 veces y cuenta las lecturas lógicas, o sea,
> cuántos bloques tuvo que leer, y los milisegundos por ejecución."

1. **Q1 → Medir** (índice compuesto).

   💻 El panel abierto muestra el `CREATE INDEX ix_reserva_aloj_checkin ON
   reserva (id_alojamiento, fecha_checkin)`.
   > "La agenda de llegadas de un alojamiento en un mes. Antes, el plan hacía
   > `TABLE ACCESS FULL` sobre 25.000 reservas. Creamos un índice
   > **compuesto**: primero la columna de igualdad, el alojamiento, y después
   > la de rango, la fecha. Así las entradas que sirven quedan juntas.
   > Después el plan usa `INDEX RANGE SCAN`: de unas 299 a 74 lecturas lógicas
   > y el tiempo baja (señalar la columna *ms / ejec.*)."
2. **Q2 → Medir** (basado en función).
   > "Buscar un cliente por correo sin importar mayúsculas: `UPPER(email)`.
   > Lo curioso es que CLIENTE ya tenía índice sobre email, pero la función lo
   > inutiliza. Creamos un índice **basado en función** sobre `UPPER(email)`:
   > de 53 a 4 lecturas lógicas."
3. **Q3 → Medir** (FK sin índice).
   > "El historial de un cliente: la llave foránea `id_cliente` no tenía
   > índice. Con el índice, de 255 a 20 lecturas. Y de paso evita que borrar
   > un cliente bloquee la tabla de reservas entera."

> "Le paso la palabra a Sebastián, que va a mostrar el caso donde el índice
> no ayuda."

---

## Parte 5 · Sebastián — El índice que no ayuda (2 min)

🖥 **Interfaz:** misma pantalla, **Q4 → Medir**.
💻 **Código:** el panel muestra `CREATE INDEX ix_reserva_estado ON reserva
(estado)` y el `DROP INDEX` del final.

> "Este es el caso donde el índice **no ayuda**: el valor de las reservas
> COMPLETADAS por alojamiento, filtrando por estado. Creamos un índice sobre
> estado y miren el plan: el optimizador lo **ignora** y sigue haciendo
> barrido completo. Si lo obligamos con la pista `INDEX`, es peor: lee más
> bloques y tarda más del doble.
>
> ¿Por qué? Porque COMPLETADA es casi el **80 % de las reservas**. Un índice
> B-tree sirve para encontrar pocas filas. Para traer el 80 % de la tabla por
> índice, Oracle tiene que saltar fila por fila a los bloques de la tabla,
> visitando los mismos bloques muchas veces; el barrido completo los lee una
> sola vez y en bloque. Por eso al final lo borramos: un índice que no se
> usa solo hace más lentas las escrituras."

Opcional: **Q5 → Medir** → "un índice por función sobre el mes tampoco
conviene: las reservas de un mes están dispersas en casi todos los bloques
(*clustering factor*)."

---

## Parte 6 · Sebastián — Las dos consultas nuevas (2 min)

🖥 **Interfaz:** **Entrega 3 → Consultas de la sustentación**.
💻 **Código:** cada consulta tiene su panel *Ver el código* (es el texto del
script `sql/20_consultas_sustentacion.sql`, que es lo que se ejecuta).

1. **Habitación con más reservas en temporada alta.**
   > "La temporada no está en la reserva sino en el calendario, porque una
   > estadía puede cruzar dos temporadas. Por eso contamos noche por noche con
   > la vista `v_noche_vendida` unida a TEMPORADA, filtrando las noches de tipo
   > ALTA, y contamos reservas distintas por habitación. Usamos `RANK` para no
   > dejar por fuera un empate. La primera fila resaltada es la respuesta:
   > la habitación 102 de Finca La Cascada 38, en Buenavista, con 46 reservas que tuvieron noches en temporada alta (leer el dato de la pantalla: si la base se vuelve a generar, puede cambiar)."
2. **Clientes con los municipios.**
   > "La segunda pregunta la resolvimos de dos formas. En la 2a, los clientes
   > que han visitado más municipios distintos, con la lista de esos
   > municipios armada con `LISTAGG` —son los viajeros de ruta cafetera—.
   > En el primer lugar, Santiago Ospina Muñoz, de Medellín, estuvo en 11 de los 12 municipios en 14 reservas, y al lado se ve en cuáles y cuántas veces (leer el nombre de la pantalla: si la base se vuelve a generar, puede cambiar). En la 2b, en cada municipio, el cliente con más
   > reservas, con `RANK` particionado por municipio."

---

## Parte 7 · Sebastián — ¿Qué hace diferente a TurismoUQ? y cierre (1,5 min)

🖥 **Interfaz:** volver a la portada.

> "Para cerrar, lo que creemos que hace diferente nuestro proyecto:
>
> **Primero, el modelo de temporadas.** No guardamos la temporada en la
> reserva: tenemos un calendario, `DIM_TIEMPO`, donde cada día sabe a qué
> temporada pertenece. Así una estadía del 13 al 18 de diciembre se cobra
> noche por noche con la tarifa correcta, y consultas como la de temporada
> alta salen de forma natural.
>
> **Segundo, la regla de negocio la protege la base, no la aplicación.** La
> disponibilidad la validan el procedimiento, el disparador y el bloqueo
> `FOR UPDATE`; la recepción ni siquiera puede ver las tablas, solo vistas
> filtradas por su propio hotel.
>
> **Tercero, una pasarela de pagos integrada a la transacción.** El rechazo
> del banco no deja datos a medias: produce un rollback parcial y la reserva
> queda pendiente para pagar después.
>
> **Y cuarto, todo es medible y reproducible:** los scripts corren desde cero,
> las pruebas imprimen OK o FALLA, y medimos los índices con lecturas lógicas,
> incluido el caso donde el índice no ayuda.
>
> Eso es TurismoUQ. Muchas gracias, profesora."

---

## Si algo falla mientras graban

| Síntoma | Qué hacer |
|---|---|
| La interfaz no abre o dice que no conecta | `docker ps`: si `oracle-xe` no aparece, `docker start oracle-xe` y esperar `READY TO USE` |
| Concurrencia *ANTES* no muestra 2 reservas | Volver a presionar el botón |
| Pagos: "la habitación no está disponible" (`-20002`) | Elegir otra habitación u otras fechas |
| La pasarela dice "solo acepta tarjetas de prueba" | Hacer clic en una fila de la tabla *Modo de pruebas* en vez de escribir |
| Seguridad: `ORA-02391` | Hay sesiones abiertas de ese usuario (por ejemplo en SQL Developer): cerrarlas |
