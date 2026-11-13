"""
TurismoUQ Pagos · pasarela de pagos SIMULADA (modo pruebas).

Hace lo que hace una pasarela real frente al comercio: recibe los datos de
pago, los valida, "consulta al banco" y devuelve una respuesta (aprobado o
rechazado) con un número de transacción. No se conecta a ningún banco ni
mueve dinero: solo acepta las tarjetas de prueba de abajo, igual que el
modo sandbox de Wompi, PayU o Stripe.

Seguridad: el número de tarjeta y el CVV no se guardan en ninguna parte ni
se envían a la base de datos. A la base solo llegan la respuesta, el número
de transacción y, en OBSERVACIONES, la marca y los últimos 4 dígitos.

Lo que pasa con la reserva según la respuesta NO se decide aquí: lo decide
pkg_transacciones (sql/14) dentro de la transacción de Oracle.
"""

import secrets
from datetime import date

# Tarjetas de prueba: número -> (respuesta, motivo de rechazo)
TARJETAS_PRUEBA = {
    "4242424242424242": ("APROBADO", None),
    "5555555555554444": ("APROBADO", None),
    "4000000000000002": ("RECHAZADO", "fondos insuficientes"),
    "4000000000000069": ("RECHAZADO", "tarjeta vencida según el banco"),
    "4000000000009987": ("RECHAZADO", "tarjeta reportada como robada"),
}

# Bancos de prueba para PSE: código -> (nombre, respuesta, motivo)
BANCOS_PSE = {
    "cafe": ("Banco del Café (pruebas, aprueba)", "APROBADO", None),
    "palma": ("Banco de la Palma (pruebas, rechaza)", "RECHAZADO", "el banco no autorizó el débito"),
}


class DatosInvalidos(ValueError):
    """Los datos del formulario no pasan la validación: no se procesa nada."""


def _luhn_valido(numero):
    total = 0
    for i, d in enumerate(reversed(numero)):
        n = int(d)
        if i % 2 == 1:
            n *= 2
            if n > 9:
                n -= 9
        total += n
    return total % 10 == 0


def _marca(numero):
    if numero.startswith("4"):
        return "VISA"
    if numero[:2] in {"51", "52", "53", "54", "55"} or numero[:4] in {"2221", "2720"}:
        return "MASTERCARD"
    if numero[:2] in {"34", "37"}:
        return "AMEX"
    return "TARJETA"


def _referencia():
    return "TUQ-" + secrets.token_hex(5).upper()


def autorizar_tarjeta(numero, vencimiento, cvv, titular, tipo):
    """Valida la tarjeta y devuelve la respuesta de la pasarela.

    tipo: 'credito' o 'debito'. Lanza DatosInvalidos si el formulario está
    mal diligenciado (en ese caso no hay transacción ni referencia)."""
    numero = "".join(ch for ch in (numero or "") if ch.isdigit())
    if not (13 <= len(numero) <= 19) or not _luhn_valido(numero):
        raise DatosInvalidos("El número de tarjeta no es válido.")
    if not (titular or "").strip():
        raise DatosInvalidos("Escribe el nombre del titular como aparece en la tarjeta.")
    if not (cvv or "").isdigit() or len(cvv) not in (3, 4):
        raise DatosInvalidos("El código de seguridad (CVV) tiene 3 o 4 dígitos.")
    try:
        mes, anio = (vencimiento or "").replace(" ", "").split("/")
        mes, anio = int(mes), 2000 + int(anio)
        if not 1 <= mes <= 12:
            raise ValueError
    except ValueError:
        raise DatosInvalidos("La fecha de vencimiento va en formato MM/AA.")
    hoy = date.today()
    if (anio, mes) < (hoy.year, hoy.month):
        raise DatosInvalidos("La tarjeta está vencida.")
    if numero not in TARJETAS_PRUEBA:
        raise DatosInvalidos(
            "La pasarela está en modo de pruebas y solo acepta las tarjetas de prueba "
            "de la lista. No escribas datos de una tarjeta real.")

    respuesta, motivo = TARJETAS_PRUEBA[numero]
    marca = _marca(numero)
    return {
        "respuesta": respuesta,
        "motivo": motivo,
        "referencia": _referencia(),
        "medio_pago": "TARJETA_CREDITO" if tipo == "credito" else "TARJETA_DEBITO",
        "descripcion": f"{marca} ···· {numero[-4:]}",
    }


def autorizar_pse(banco, titular):
    if banco not in BANCOS_PSE:
        raise DatosInvalidos("Selecciona tu banco.")
    if not (titular or "").strip():
        raise DatosInvalidos("Escribe el nombre del titular de la cuenta.")
    nombre, respuesta, motivo = BANCOS_PSE[banco]
    return {
        "respuesta": respuesta,
        "motivo": motivo,
        "referencia": _referencia(),
        "medio_pago": "PSE",
        "descripcion": f"PSE · {nombre.split(' (')[0]}",
    }
