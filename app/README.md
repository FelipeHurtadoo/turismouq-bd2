# TurismoUQ · Interfaz administrativa (Flask)

No es parte de lo que exige el documento del proyecto (la Entrega 2 dice
explícitamente que el entregable es la base de datos, no una interfaz), pero
ayuda a demostrar en vivo que la capa PL/SQL funciona: esta app llama
directamente a `PKG_TURISMO` y a las vistas/consultas de la Entrega 1 sobre
el mismo esquema `TURISMO_UQ`. No modifica, ni necesita modificar, ningún
script de `sql/`.

## Requisitos

- El contenedor `oracle-xe` ya corriendo con el esquema `TURISMO_UQ` cargado
  (scripts `sql/01` a `sql/11` ya ejecutados — ver el `README.md` de la raíz
  del repositorio).
- Para el menú **Entrega 3**, además, los scripts `sql/13` a `sql/18`
  (paquetes `PKG_TRANSACCIONES` y `PKG_MEDICION`, índices, roles y usuarios
  de demostración). Sin ellos esas cuatro pantallas dan error; el resto de la
  app funciona igual.
- Python 3.10 o superior.

## Arranque rápido (sin Docker para la app)

**Solo la primera vez** (instala dependencias en un entorno virtual):

```bash
cd app
python -m venv .venv
.venv\Scripts\activate          # en Windows (PowerShell/cmd)
# source .venv/bin/activate     # en Linux/Mac

pip install -r requirements.txt

copy .env.example .env          # Windows
# cp .env.example .env          # Linux/Mac
# Edita .env si tu usuario/contraseña/puerto no son los por defecto.
```

**Cada vez que quieras volver a abrirla** (con el contenedor `oracle-xe` ya
encendido): solo hacen falta estas dos líneas, no hay que reinstalar nada.

```bash
cd app
.venv\Scripts\activate
python app.py
```

Abre `http://localhost:5000`.

python-oracledb corre en **modo thin** (puro Python): no hace falta instalar
Oracle Instant Client en la máquina para esto.

## Arranque con Docker (opcional, alternativa al venv)

Útil si no quieres depender de recordar activar el venv, o si vas a demostrar
el proyecto desde otro equipo. **No reemplaza ni toca el contenedor
`oracle-xe`**, que sigue encendiéndose aparte con `docker start oracle-xe`
(ver README.md de la raíz, sección 2.1) — este compose solo levanta la app.

```bash
cd app
docker compose up --build
```

Eso construye la imagen la primera vez y la reutiliza después; para
reconstruir tras cambiar el código: `docker compose up --build` de nuevo.
Para pararla: `docker compose down`.

(La versión con `docker run` plano, por si no tienes `docker compose`
disponible:)

```bash
cd app
docker build -t turismouq-web .
docker run --rm -p 5000:5000 --env-file .env ^
   -e DB_DSN=host.docker.internal:1521/XEPDB1 ^
   turismouq-web
```

`host.docker.internal` es necesario porque, a diferencia de `localhost`, es
como un contenedor en Docker Desktop (Windows/Mac) alcanza un puerto
publicado por OTRO contenedor (`oracle-xe`) que no está en la misma red.

## Qué hace cada pantalla

| Pantalla | Qué llama en la base |
|---|---|
| Nueva reserva | `pkg_turismo.sp_crear_reserva` (vía un bloque anónimo, ver nota abajo) |
| Reservas recientes | `SELECT` sobre `RESERVA` / `CLIENTE` / `ALOJAMIENTO` |
| Liquidación mensual | la misma consulta del cursor explícito `c_liq` de `sp_liquidar_mes` |
| 8 consultas de análisis | las mismas consultas de `sql/08_consultas_analisis.sql`, parametrizadas |
| Auditoría de tarifas | `SELECT` sobre `AUDITORIA_TARIFA`, la tabla que llena `trg_tarifa_auditoria` |
| **Entrega 3 → Transacciones** | `pkg_transacciones.sp_reservar_y_pagar` con un pago válido o inválido; botón "paso a paso" con los conteos después de cada `SAVEPOINT` / `ROLLBACK TO` |
| **Entrega 3 → Concurrencia** | Dos conexiones reales (A y B) por la misma habitación + una tercera que consulta `V$SESSION`: sin bloqueo (`pkg_turismo.sp_crear_reserva`), con `FOR UPDATE` y con `NOWAIT` (`pkg_transacciones.sp_crear_reserva_segura`) |
| **Entrega 3 → Índices** | `pkg_medicion.plan` y `pkg_medicion.medir` sobre Q1–Q5, antes y después; cuadro para medir cualquier `SELECT` en vivo |
| **Entrega 3 → Seguridad** | Se conecta como `recep1`, `recep2`, `admin1`, `gerente1` o `auditor1` y corre la batería de `sql/19_pruebas_seguridad.sql`; prueba el límite de 2 sesiones del perfil; matriz de privilegios desde `USER_TAB_PRIVS_MADE` |

### Entrega 3: qué tener en cuenta

- Las reservas que crean estas pantallas llevan `DEMO_E3 web` en
  `OBSERVACIONES`. La de Concurrencia las borra al terminar; las de
  Transacciones se borran con el botón **Limpiar reservas de demostración**.
- En **Índices**, el "antes" de Q1–Q3 no borra el índice: usa la pista
  `/*+ NO_INDEX(...) */`, que para el optimizador equivale a no tenerlo. Los
  índices de Q4 y Q5 (los que no ayudan) se crean y se borran dentro de la
  misma medición.
- En **Seguridad**, cada prueba termina con `ROLLBACK`: no queda ningún cambio.
- Estas pantallas abren conexiones propias (fuera del pool) porque necesitan
  sesiones independientes o conectarse con otro usuario.

### Nota técnica: por qué la reserva se crea con un bloque anónimo

`pkg_turismo.t_lista_habitaciones` es una tabla asociativa declarada DENTRO
del paquete (`TYPE ... IS TABLE OF ... INDEX BY PLS_INTEGER`), no un `TYPE`
de esquema. Un cliente externo como python-oracledb no puede enlazar ese
tipo directamente como parámetro. En vez de cambiar la firma de
`sp_crear_reserva` (que ya quedó validada para la Entrega 2), la app arma la
colección **dentro de un bloque PL/SQL anónimo** que recibe solo escalares
(`h1`..`h6`, uno por casilla de habitación marcada) y construye
`v_habs` ahí mismo antes de llamar al procedimiento real. `sp_crear_reserva`
en sí no cambió ni una línea.
