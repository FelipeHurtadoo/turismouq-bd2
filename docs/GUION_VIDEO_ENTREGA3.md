# TurismoUQ · Guion para grabar el video de la Entrega 3

Duración sugerida: **12 a 15 minutos**. Si la docente indicó otra duración,
recorte las partes marcadas como *opcional*. Cada bloque dice qué abrir, qué
hacer y qué decir; las frases entre comillas son una guía, no un libreto.

---

## Antes de grabar (10 minutos de preparación)

1. Encender Docker Desktop y luego el contenedor:
   ```bash
   docker start oracle-xe
   ```
   Esperar `DATABASE IS READY TO USE!` en `docker logs -f oracle-xe`.
2. Encender la interfaz web:
   ```bash
   cd app
   .venv\Scripts\activate
   python app.py
   ```
   Abrir `http://localhost:5000` en el navegador, con el zoom al 110–125 %
   para que se lea bien en el video.
3. Abrir **SQL Developer** con la conexión `turismo_uq` y dejar abiertos en
   pestañas: `sql/14_pkg_transacciones.sql`, `sql/17_indices.sql`,
   `sql/18_seguridad.sql`. Activar *Ver → Salida de DBMS* para `turismo_uq`.
4. Hacer **una pasada de prueba sin grabar** de todo el guion: el primer clic
   de cada pantalla es más lento (compila y llena cachés).
5. Cerrar notificaciones (WhatsApp, correo) y ocultar contraseñas que no sean
   las de demostración.
6. Grabar con OBS, la barra de juegos de Windows (`Win + Alt + R`) o la
   herramienta que indique la docente, con micrófono.

---

## 1. Presentación (1 minuto)

**Pantalla:** portada de la interfaz (`http://localhost:5000`).

> "Somos el equipo 01D: Juan Felipe Hurtado, Santiago Marín y Sebastián
> Agudelo. Esta es la Entrega 3 de TurismoUQ: transacciones, concurrencia,
> índices y seguridad, sobre Oracle XE 21c. Toda la lógica vive en la base de
> datos; la interfaz web solo llama a los paquetes PL/SQL para que se vea en
> vivo."

Mostrar rápido el repositorio: carpeta `sql/` con los scripts del 01 al 19
y `docs/`.

## 2. Transacciones con SAVEPOINT y pasarela de pagos (3 minutos)

**Pantalla:** SQL Developer, `sql/14_pkg_transacciones.sql`, procedimiento
`sp_reservar_y_pagar`.

> "El procedimiento tiene dos savepoints. `sp_inicio` antes de crear la
> reserva: si la reserva falla se deshace todo. `sp_antes_pago` antes del
> pago: si el pago falla, se deshace solo el pago y la reserva queda
> pendiente. Ese es el rollback parcial."

**Pantalla:** interfaz → **Operación → Nueva reserva**.

1. Buscar un cliente (por ejemplo `CC` y un documento existente), elegir un
   alojamiento, fechas cercanas y una habitación. Clic en **Calcular valor
   estimado** ("esto lo calcula `fn_valor_estadia` noche por noche").
2. Clic en **Continuar al pago**. Mostrar el resumen.
3. En *Modo de pruebas*, clic en la tarjeta `4000 0000 0000 0002`
   (fondos insuficientes) y **Pagar**.
4. En el resultado: "El banco rechazó. La reserva quedó **PENDIENTE** con
   cero pagos: el procedimiento hizo `ROLLBACK TO sp_antes_pago`."
5. Clic en **Intentar el pago de nuevo**, tarjeta `4242 4242 4242 4242`,
   **Pagar**. "Ahora `sp_registrar_pago` bloqueó la reserva con
   `FOR UPDATE`, insertó el pago y la reserva quedó **CONFIRMADA**."

**Pantalla:** **Entrega 3 → Transacciones** → **Ejecutar paso a paso**.

> "Aquí se ve el savepoint por dentro: después del `ROLLBACK TO
> demo_antes_pago` los pagos vuelven a cero pero la reserva sigue; un
> savepoint no termina la transacción, solo la recorta."

*Opcional:* botón **Reserva inválida (-20003)**: "rollback total, no quedó
nada grabado".

## 3. Concurrencia: dos sesiones, la misma habitación (3 minutos)

**Pantalla:** **Entrega 3 → Concurrencia**.

1. Clic en **ANTES · sin bloqueo**. Esperar ~5 s.
   > "Dos sesiones reales reservan la misma habitación. B no ve la reserva sin
   > confirmar de A, por la lectura consistente de Oracle, así que la
   > habitación quedó **vendida dos veces**. Ni el procedimiento ni el
   > disparador de la Entrega 2 lo evitan."
2. Clic en **DESPUÉS · con SELECT ... FOR UPDATE**.
   > "Ahora A bloquea la fila de HABITACION. El monitor muestra en
   > `V$SESSION` que la sesión B está **bloqueada** por A, con el evento
   > `enq: TX - row lock contention`. Cuando A confirma, B continúa, vuelve a
   > validar y es rechazada con `ORA-20002`. Solo queda una reserva."
3. Clic en **NOWAIT**: "B no espera: falla al instante con `ORA-20006`."

*Opcional, si quieren mostrarlo con dos ventanas de SQL Developer:* seguir la
sección 11.1 del `README.md` con `16a`, `16b` y `16c` (hojas no
compartidas, Ctrl+Shift+N).

## 4. Índices (3 minutos)

**Pantalla:** **Entrega 3 → Índices**.

1. **Q1 → Medir**. "Índice compuesto `(id_alojamiento, fecha_checkin)`:
   igualdad primero, rango después. Pasa de `TABLE ACCESS FULL` a
   `INDEX RANGE SCAN` y de 299 a 74 lecturas lógicas por ejecución."
2. **Q2 → Medir**. "Índice basado en función `UPPER(email)`. CLIENTE ya tenía
   índice sobre email, pero la función lo inutiliza. De 53 a 4 lecturas."
3. **Q3 → Medir**. "La FK `id_cliente` sin índice: de 255 a 20."
4. **Q4 → Medir**. "El caso donde el índice **no ayuda**: `COMPLETADA` es el
   80 % de las filas. El optimizador ignora el índice y, si lo forzamos,
   lee más bloques y tarda más del doble que el barrido completo. Un índice
   B-tree sirve para encontrar pocas filas."
5. *Opcional:* **Q5** (clustering factor) y el cuadro **Medir cualquier
   consulta**.

## 5. Seguridad (2 minutos)

**Pantalla:** SQL Developer, `sql/18_seguridad.sql`, la parte de vistas y
`CREATE PROFILE`.

> "Cuatro roles. Recepción solo tiene `SELECT` sobre dos vistas y `EXECUTE`
> sobre el paquete transaccional: ninguna tabla. Las vistas filtran por el
> usuario conectado con `SYS_CONTEXT('USERENV','SESSION_USER')` contra
> `USUARIO_SISTEMA`, que existe desde la Entrega 1."

**Pantalla:** **Entrega 3 → Seguridad**.

1. **RECEP1**: mostrar "10 / 10 como se esperaba": ve su vista, reserva en su
   alojamiento, y Oracle rechaza la tabla `RESERVA` (`ORA-00942`) y el
   alojamiento ajeno (`ORA-20020`).
2. **RECEP2**: "misma vista, otras filas: solo el alojamiento 2".
3. **AUDITOR1**: lee la auditoría, no puede borrarla ni ver clientes.
4. **Abrir 3 sesiones como RECEP1**: "la tercera la rechaza el perfil con
   `ORA-02391`: máximo dos sesiones por usuario".

## 6. Cierre (30 segundos)

> "Todos los scripts corren de arriba abajo en una base limpia; las salidas
> completas de las pruebas están en `docs/evidencia/` y la documentación en
> `docs/DOCUMENTACION_ENTREGA3.md` y en el PDF de la entrega."

---

## Si algo falla durante la grabación

| Síntoma | Qué hacer |
|---|---|
| La interfaz dice que no conecta | `docker ps`: si `oracle-xe` no aparece, `docker start oracle-xe` y esperar |
| Concurrencia "ANTES" no muestra 2 reservas | Volver a presionar el botón (el primer intento a veces es lento) |
| Seguridad: "No se pudo conectar como RECEP1" | Ejecutar `sql/18_seguridad.sql` en SQL Developer |
| Seguridad: `ORA-02391` al elegir RECEP1 | Hay dos sesiones de RECEP1 abiertas (por ejemplo en SQL Developer): cerrarlas |
| Pagos: "no hay habitación libre" o `-20002` | Elegir otras fechas u otra habitación |
