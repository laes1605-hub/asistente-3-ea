# Asistente 3 EA

La versión de riesgo porcentual es `Asistente 3 - TP Fijo.mq5` (v5.50).


## Novedades v5.50: reset, cierres manuales y diagnóstico

### Reiniciar el máximo histórico

En **CONFIG → Reiniciar máximo al balance actual**, confirma el aviso. El máximo pasa al
**balance actual de la cuenta** (no a la equidad ni a cero, salvo que el balance sea cero).
Por ejemplo: máximo 1,200, balance tras un retiro 800 → nuevo máximo 800; con riesgo del 4%,
el objetivo pasa de 48 a 32. Desde ese momento vuelve a subir cuando el balance supere el nuevo máximo.

- Recalcula riesgo y lote, sin cerrar posiciones ni cambiar sus SL/TP.
- Se guarda en la variable global de cuenta y en `MQL5/Files/GQP_HWM_*.dat`.
- Se comparte entre símbolos y magic numbers de la misma cuenta/servidor/moneda **en el mismo terminal**.
  Los demás gráficos recogen el cambio en el siguiente tick/temporizador, incluso al guardar o salir.
- Es distinto de **Reiniciar base**: en modo capital base, reiniciar el máximo histórico **no** modifica
  el capital base ni su referencia. Usa el botón de base si lo que deseas es reiniciar ese cálculo.
- Actualiza **todas** las instancias de TP Fijo a v5.50: una versión antigua no conoce la nueva sincronización.
- Si no puede guardar el respaldo en archivo, lo avisa; el valor queda en la variable global del terminal.

### Cerrar operaciones del par

En **POSIC.**, cada posición tiene **Cerrar** y cada pendiente tiene **Cancelar**. El botón
**CERRAR TODO [símbolo] (incl. pendientes)** cancela las pendientes y cierra las posiciones del par.
Todas estas acciones piden confirmación (la opción predeterminada es No).

**Alcance de los cierres manuales:** todas las operaciones del símbolo del gráfico, incluidas las
manuales y las de otros EA/magic numbers. **No toca otros símbolos.** Abarca pendientes LIMIT, STOP
y STOP LIMIT. Los cierres automáticos del viernes siguen limitados al símbolo + magic del EA.

El cierre individual usa el ticket completo, no el número de fila, para no cerrar otra operación
si cambia la lista. En cuentas *hedging* permite cerrar cada posición por separado; en cuentas
*netting* MetaTrader consolida las entradas del símbolo en una única posición y se cierra esa posición completa.
Los filtros de sesión y de entrada del viernes no bloquean estos cierres manuales, pero siguen siendo
necesarios conexión, permisos de trading y un mercado que permita ejecutarlos.

Un rechazo, una ejecución parcial o una solicitud todavía sin confirmar **no se anuncian como cierre total**.
El cierre del par intenta el resto de tickets y muestra un resumen con el último fallo; el registro
conserva el detalle de cada uno. Revisa POSIC. antes de repetir: no hay reenvíos automáticos y otro EA
podría volver a abrir operaciones por su cuenta.

### Por qué no abre una operación

La franja **ÚLTIMA ACCIÓN**, visible en todas las pestañas, muestra el resultado y conserva el último
mensaje mientras el EA está activo. Si no cabe, coloca el cursor sobre el texto para ver el mensaje
completo; también aparece en **Caja de herramientas → Expertos**.

Se comprueban permisos/Algo Trading, conexión, riesgo/lote, configuración del split, SL/TP positivos,
horario, cierre preventivo del viernes, dirección permitida y precio LIMIT (BUY debajo de ASK,
SELL encima de BID). Antes de enviar se ejecuta `OrderCheck`; los rechazos incluyen el motivo, código
MT5, error local y comentario del broker: margen insuficiente, mercado cerrado, volumen inválido,
SL/TP demasiado cercanos, modo de ejecución no admitido, etc.

En operaciones divididas, se valida que ninguna parte quede por debajo del mínimo antes de enviar.
Si falla una parte, o una entrada a mercado queda parcial/sin confirmar, se detiene el resto y se indica
cuántas solicitudes fueron aceptadas. **Las partes ya ejecutadas no se deshacen**: revisa POSIC. antes
de volver a pulsar BUY/SELL. La aceptación de una LIMIT significa que se colocó la pendiente, no que
ya se haya ejecutado.

El JSON añade `last_action_message`, `last_action_error` y `last_action_time` (hora del servidor como
entero `datetime` de MQL5). El texto se escapa para admitir comentarios del broker con comillas o saltos de línea.

### Instalación y validación

1. Abre **`Asistente 3 - TP Fijo.mq5`** en MetaEditor y compila con **F7**.
2. Usa el nuevo **`Asistente 3 - TP Fijo.ex5`** en los gráficos; el `Asistente 3.ex5` del repositorio
   corresponde a otra versión y **no** contiene estos cambios. `Asistente 3.mq5` tampoco se ha modificado.
3. Prueba primero en demo siguiendo [la lista de comprobación](tests/MT5_CHECKLIST.md).

Pruebas locales: `python -m unittest discover -s tests -v` (Python 3 y `g++`). Revisan contratos del
código y ejecutan funciones extraídas con API de terminal simulada. **No sustituyen la compilación
MQL5, el Strategy Tester ni las pruebas con el broker.** No se genera un `.ex5` en este entorno.

## Panel OPERAR

La barra superior muestra cinco cifras que se ven desde cualquier pestaña:

| Celda | Qué muestra |
|-------|-------------|
| RIESGO | Importe objetivo por operación (monto redondeado hacia arriba) |
| SI PIERDE | Pérdida estimada si salta el SL |
| SI GANA | Ganancia estimada si salta el TP |
| EQUIDAD | Equity actual de la cuenta |
| LOTE | Lotaje que se usará en la próxima operación |

La moneda de la cuenta se indica una sola vez, a la derecha de la barra de título. Los importes grandes se
abrevian (`100.0K`, `1.25M`) para que quepan en la celda. El valor de LOTE se pinta en naranja —y con `⚠`—
cuando el broker obliga a usar su lote mínimo o máximo.

Debajo, OPERAR muestra un bloque **informativo** con el riesgo activo (`RIESGO 4% · BASE ...`), el precio
para las órdenes LIMIT con sus botones de ayuda (`USAR ASK`, `USAR BID`, `RESET`) y los botones BUY / SELL / BUY LIMIT / SELL LIMIT. Las pestañas CUENTA, POSIC. y
CONFIG se mantienen.

## Riesgo porcentual

`InpRiskPercent` es el porcentaje que se arriesga por operación (por defecto, 4%). **Solo se puede cambiar
en las Entradas de MetaTrader**: el panel ya no tiene campo editable y los comandos del dashboard
(`set_risk_percent` / `set_risk_usd`) se ignoran con un aviso en el log. El monto objetivo se redondea hacia
arriba a la unidad entera de la moneda de la cuenta (4% de 1,001 = 40.04 → 41); el lote se ajusta hacia abajo
al paso del broker. Si el lote mínimo supera el objetivo, se usa el mínimo y se indica la advertencia
correspondiente.

## Base de cálculo del riesgo

El porcentaje se aplica sobre una **base**, y hay dos modos (`InpRiskBaseMode`):

- **Balance completo** (`RISK_BASE_FULL_BALANCE`, por defecto): la base es el máximo balance histórico de la
  cuenta. Máximo 1,000 → riesgo 40; al llegar a 1,200 → 48; si el balance cae a 1,056 el riesgo sigue siendo
  48 hasta que el balance supere 1,200. El máximo se conserva entre reinicios y entre gráficos de la misma
  cuenta.
- **Capital base** (`RISK_BASE_CAPITAL`): se arriesga sobre un importe fijo, no sobre el balance completo. Con
  `InpBaseCapital = 1500` en una cuenta de 10,000, la base arranca en 1,500 y el riesgo inicial es 60 (4%).
  A partir de ahí **la base crece con todas las ganancias posteriores y nunca baja**: si el balance sube a
  10,300, la base pasa a 1,800 y el riesgo a 72; si después el balance cae a 10,100, la base se queda en
  1,800. Solo toma los 1,500 iniciales del balance, pero capitaliza todo lo que esos 1,500 vayan ganando.

  El balance de referencia se captura la primera vez que el EA corre con ese capital base y se guarda
  (variable global + `Terminal\MQL5\Files\GQP_BASE_*.dat`), de modo que sobrevive a reinicios y cambios de
  gráfico. Se reinicia automáticamente cuando cambias `InpBaseCapital`, o a mano con el botón
  **⟲ Reiniciar base** de la pestaña CONFIG (toma el balance actual como nueva referencia).

  Los depósitos y retiros mueven el balance igual que una ganancia o una pérdida: si haces un depósito
  grande y no quieres que cuente como ganancia de la base, pulsa **⟲ Reiniciar base**.

En CONFIG se puede ver el modo activo, la base actual, el capital base y el balance de referencia; en CUENTA,
la base de riesgo y el lote de la próxima operación.

## Horarios y cierres

En las propiedades del EA (MetaTrader → Entradas):

- `InpUseSessionFilter`: activa el horario de sesión (desactivado de forma predeterminada para no bloquear entradas sin configuración).
- `InpSessionStart` / `InpSessionEnd`: horario diario en hora del servidor del broker, formato `HH:MM`. Fuera de ese horario no permite abrir operaciones nuevas. Al terminar, elimina las órdenes BUY LIMIT y SELL LIMIT creadas por este EA; deja abiertas las posiciones que ya estén activas. Admite sesiones que cruzan medianoche.
- `InpCloseBeforeFridayMarketEnd`: cierra las posiciones de este EA y cancela sus órdenes pendientes LIMIT y STOP (incluidos STOP LIMIT) el viernes.
- `InpFridayCloseMinutes`: por defecto, 30 minutos antes del último cierre de sesión del símbolo publicado por el broker. Si MetaTrader no informa el horario, usa `InpFridayMarketCloseFallback` (por defecto `23:59`, hora del servidor).

Los cierres automáticos solo abarcan el símbolo del gráfico y el `InpMagicNumber` de esta instancia; no modifican operaciones ajenas al EA. El terminal debe permanecer abierto, con el EA activo y el trading algorítmico permitido para que el temporizador ejecute los cierres.

## JSON para el dashboard

El estado exportado (`GQP_*_state.json`) mantiene los campos anteriores y añade los de la base de riesgo:

- `risk_base_mode`: `full_balance` o `capital_base`.
- `risk_base`: base efectiva sobre la que se aplica el porcentaje.
- `risk_base_capital` y `risk_base_start_balance`: capital base configurado y balance de referencia.
- `lots_mode` pasa a `from_capital_base_percent` cuando se usa capital base.
- `expected_loss_percent_risk_base` (el campo `expected_loss_percent_high_water` se mantiene y ahora es
  relativo a la base activa).

El riesgo es de solo lectura para el dashboard: cualquier intento de cambiarlo por comando se ignora.
