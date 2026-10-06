# Pruebas de activación (español)

Compruébalas contra la `description` de `SKILL.md` cada vez que la edites. Lista en inglés: [trigger-tests.md](trigger-tests.md).

## Debe activarse

| Consulta | Motivo |
| --- | --- |
| orquesta tres agentes en herdr para documentar estos módulos | Corrida multiagente en herdr |
| reparte esta tarea entre workers en panes de herdr | Tarea repartida en panes worker |
| lanza workers de codex y claude en herdr para este refactor | Workers de tipos mixtos |
| usa herdr para correr workers en paralelo y verificar cada resultado | Paralelo más verificación |
| inicia una corrida multiagente en herdr | Corrida multiagente explícita |
| despacha estas tareas a los workers de herdr y espéralas | dispatch + wait |
| retoma la corrida 20261006-docs del orquestador de herdr | Reanuda un run id existente |
| cierra la corrida del orquestador y valida el ledger | close + validación del ledger |

## No debe activarse

| Consulta | Motivo / quién la atiende |
| --- | --- |
| divide este pane a la derecha | Control manual de panes: skill herdr |
| manda ctrl+c al agente del pane w1:p2 | Control manual de panes: skill herdr |
| orquesta sesiones de OpenCode | Sesiones de OpenCode fuera de alcance (tag `opencode-final`) |
| explica qué es un agente de código | Pregunta general, sin corrida |
| arregla este bug | Un solo agente, sin orquestación |
| corre la suite de pruebas en un pane en segundo plano | Pane en segundo plano: skill herdr |
