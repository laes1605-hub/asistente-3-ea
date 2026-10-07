# Validación v5.51 en MetaTrader 5 (cuenta DEMO)

Pendiente de ejecutar en MT5: el entorno de desarrollo no dispone de MetaEditor ni del terminal.

## Compilación y panel

- [ ] Compilar `Asistente 3 - TP Fijo.mq5` con F7. Verificar que no hay errores y revisar las advertencias.
- [ ] Cargar el `.ex5` recién generado y comprobar v5.51 en el título.
- [ ] Recorrer OPERAR/CUENTA/POSIC./CONFIG; comprobar que los botones y la franja de mensajes no se solapan.
- [ ] Probar POSIC. con 0, 1 y más de 6 operaciones, scroll y tickets largos.
- [ ] Si la ventana es pequeña, ajustar `InpPanelY` para ver el panel completo.

## Reset del máximo

- [ ] Abrir dos gráficos de símbolos distintos, misma cuenta, ambos con v5.51 y distinto magic.
- [ ] Con máximo guardado mayor que el saldo, cancelar el diálogo de reset: nada debe cambiar.
- [ ] Confirmar reset: máximo = balance, no equidad; riesgo redondeado y lote recalculados.
- [ ] Verificar el otro gráfico tras su siguiente timer, guardar su estado, retirarlo y volver a cargarlo:
      no debe restaurar el máximo anterior.
- [ ] Reiniciar MT5: conservar el nuevo máximo. Verificar también `GQP_HWM_*.dat`.
- [ ] Saldo inferior al nuevo máximo: este no baja; saldo superior: el máximo sube.
- [ ] Probar saldo cero en una cuenta demo preparada para ello: guardar cero y bloquear aperturas por riesgo cero.
- [ ] En modo capital base: reset del máximo no cambia la base/referencia; el botón Reiniciar base sigue separado.
- [ ] Comprobar aislamiento entre cuentas/servidores (no compartir máximos).

## Cierres manuales

- [ ] Crear varias posiciones del mismo par (hedging), con distintos magic y una manual, más una de otro símbolo.
- [ ] Cancelar el diálogo de cierre: no enviar ninguna solicitud.
- [ ] Cerrar una posición por su botón: solo ese ticket desaparece.
- [ ] Dejar que un ticket se cierre por TP/SL mientras está abierto el diálogo: no cerrar otro ticket por accidente.
- [ ] Crear pendientes BUY/SELL LIMIT, STOP y STOP LIMIT; cancelar individualmente sin tocar las demás.
- [ ] Cerrar todo: primero cancelar pendientes, luego cerrar todas las posiciones del par; otro símbolo permanece intacto.
- [ ] En netting, explicar/confirmar que se cierra la posición agregada entera, no una entrada histórica.
- [ ] Fuera de sesión configurada, con mercado abierto: nuevas entradas bloqueadas pero cierre manual permitido.
- [ ] Algo Trading desactivado o mercado cerrado: mensaje de fallo, sin afirmar que todo está cerrado.
- [ ] Si el broker permite simular ejecución parcial/aceptada: no informar cierre total; mostrar volumen restante en POSIC.
- [ ] Cierre automático de viernes: sigue limitado al magic del EA (no al nuevo alcance manual).

## Diagnóstico de entradas

- [ ] BUY/SELL y BUY/SELL LIMIT correctos: resultado visible; LIMIT colocada no significa ejecutada.
- [ ] Sin conexión, Algo Trading apagado, permiso del EA desactivado, cuenta sin permisos: motivo específico.
- [ ] Riesgo cero, SL/TP no positivos, máximo por orden inválido: bloquear con mensaje.
- [ ] Sesión inválida/fuera de horario y franja de cierre de viernes: mostrar causa y no abrir.
- [ ] Precio LIMIT cero, BUY LIMIT sobre ASK, SELL LIMIT bajo BID: rechazo local legible.
- [ ] Mercado cerrado, margen insuficiente, SL/TP muy cercanos, volumen/tipo de orden no admitidos:
      comprobar motivo, `OrderCheck`/retcode, comentario del broker y error local en Expertos.
- [ ] Split con paso 0.001 y máximo no múltiplo del paso: suma exacta sin elevar al lote mínimo por parte.
- [ ] Split imposible por mínimo: rechazar ANTES de enviar la primera parte.
- [ ] Split que falla después de aceptar una parte: detenerse, conservar posiciones ejecutadas y advertir antes de reintentar.
- [ ] Cambiar de pestaña y esperar ticks/timer: el último mensaje no se pierde.
- [ ] Leer JSON con un parser: campos de mensaje/código de error lógico/hora presentes; comillas del comentario escapadas.

## Redondeo del lotaje v5.51

- [ ] Paso 0.01, cociente 1.231: lote 1.24. Cociente exacto 1.23: conservar 1.23.
- [ ] Paso 0.001, cociente 0.1231: lote 0.124. Paso 0.25, cociente 1.26: lote 1.50.
- [ ] Paso 1, cociente 1.23: lote 2 (solo porque ese es el paso exigido por el símbolo).
- [ ] Cociente exacto tras varias divisiones: no añadir un paso por ruido de coma flotante.
- [ ] Respetar mínimo/máximo y conservar sus advertencias al limitar el lote.
- [ ] Comprobar que SI PIERDE, SI GANA, LOTE y JSON reflejan el lote nuevo; el riesgo real puede aumentar.
- [ ] Mercado y LIMIT usan el mismo lote; la suma de las partes del split conserva el total redondeado.
