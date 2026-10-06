# herdr-orchestrator

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](SKILL/LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.0-green.svg)](SKILL/SKILL.md)
[![Platform](https://img.shields.io/badge/platform-herdr-8A2BE2.svg)](https://herdr.dev)
[![English](https://img.shields.io/badge/read%20in-English-blue.svg)](README.md)

> Skill de Claude Code que orquesta varios agentes de código dentro de [herdr](https://herdr.dev): el orquestador divide el trabajo, los workers corren en panes hermanos y cada resultado se verifica con evidencia escrita antes de cerrar la corrida.

## Qué hace

- **Un orquestador Claude que nunca implementa.** Divide la tarea, despacha archivos de tarea completos y lee solo reportes cortos, nunca transcripciones crudas de los workers.
- **Workers de tipos mixtos en panes hermanos.** `claude`, `codex`, `opencode` y otros tipos de agente corren lado a lado en la pestaña del orquestador.
- **Ledger schema 4 y compuerta de evidencia.** `.herdr-orch/<run>/ledger.yaml` registra identidad del worker, scopes y una máquina de estados explícita; una tarea es `verified` solo cuando su `evidence.yml` pasa `check_evidence.sh`.
- **Validadores POSIX.** `validate_dag.sh` y `validate_ledger_closed.sh` solo necesitan `sh` + `awk`.
- **Manejo fail-closed** de aprobaciones, timeouts y workers atascados: el orquestador nunca responde un diálogo, nunca reenvía un prompt a ciegas y reconcilia los resultados inciertos primero.

## Instalación

El nombre de la carpeta debe ser igual al `name` del skill (`herdr-orchestrator`).

```bash
git clone https://github.com/sabas1080/OpenCode-Orchestrator-Skill.git ~/.claude/skills/herdr-orchestrator-src
ln -s ~/.claude/skills/herdr-orchestrator-src/SKILL ~/.claude/skills/herdr-orchestrator   # o copia SKILL/ ahí
```

## Requisitos

| Requisito | Versión |
| --- | --- |
| herdr | >= 0.8.2 (ejecutar dentro de un pane de herdr, `HERDR_ENV=1`) |
| jq | cualquier versión reciente |
| `sh` POSIX + `awk` | para `orch.sh` y los validadores |
| git | para el modo opcional `--worktree` |

## Inicio rápido

```sh
sh SKILL/scripts/orch.sh preflight                                   # gate=ready ?
sh SKILL/scripts/orch.sh init-run --run-id 20261006-docs --worker claude --worker codex
sh SKILL/scripts/orch.sh task add --id W1 --worker 1 --scope docs/a --criterion "docs/a/README.md documents every public function of a/"
sh SKILL/scripts/orch.sh task add --id W2 --worker 2 --scope docs/b --criterion "docs/b/README.md documents every public function of b/"
sh SKILL/scripts/orch.sh dispatch --task W1 --prompt-file /tmp/w1.md
sh SKILL/scripts/orch.sh dispatch --task W2 --prompt-file /tmp/w2.md
sh SKILL/scripts/orch.sh wait --task W1 && sh SKILL/scripts/orch.sh verify --task W1
sh SKILL/scripts/orch.sh wait --task W2 && sh SKILL/scripts/orch.sh verify --task W2
sh SKILL/scripts/orch.sh close                                       # TOTAL: N passed, 0 failed
```

Otros subcomandos: `pool`, `task set`, `reconcile` (resuelve tareas `launching` / `outcome-unknown`), `suggest-count FILE` y `teardown` (simulación; `--confirm` cierra solo los panes worker de esta corrida).

### Modo de permisos de los workers (`--agent-arg`)

`init-run --agent-arg ARG` (repetible, un valor por flag) se pasa después de `--` a `herdr agent start`. Por ejemplo, para iniciar workers Claude en modo de permisos `auto`:

```sh
sh SKILL/scripts/orch.sh init-run --run-id 20261006-docs --worker claude --worker claude \
  --agent-arg --permission-mode --agent-arg auto
```

Úsalo solo para workers desatendidos que el usuario realmente quiera. Sin él, los workers inician en tu modo de permisos por defecto y se detienen en las solicitudes de aprobación, que el orquestador reporta y nunca responde.

### Confianza de carpeta

Una carpeta o worktree nuevo hace que Claude muestre su diálogo de confianza de carpeta. `init-run` imprime entonces `INCOMPLETE`; responde el diálogo tú mismo una vez en ese pane y repite `init-run` con el mismo `--run-id`. El orquestador nunca lo responde.

## Arquitectura

```
pane orquestador (Claude)
        |
        v
  orch.sh  --->  CLI de herdr  --->  panes worker (claude | codex | opencode ...)
        |
        v
.herdr-orch/<run>/
    ledger.yaml          schema 4, escrito solo por orch.sh
    workers.tsv          registro de workers (identidad)
    <task>/prompt.md     archivo de tarea compuesto
    <task>/report.md     reporte corto del worker
    <task>/evidence.yml  criterion, result, observed
```

## Aceptación en vivo

Ejecutada contra herdr 0.8.2 real con 2 workers `claude` (modo de permisos `auto`): ambas tareas se completaron y verificaron, `close` imprimió `TOTAL: 4 passed, 0 failed` y `teardown --confirm` cerró exactamente los dos panes worker. Dos intentos previos se detuvieron donde las reglas lo exigen (diálogo de confianza, solicitud de aprobación). Detalles: [docs/superpowers/acceptance/2026-10-06-e2e.md](docs/superpowers/acceptance/2026-10-06-e2e.md).

## Pruebas

```sh
sh tests/run_validators.sh   # validadores
sh tests/run_orch.sh         # orch.sh contra un herdr simulado
sh tests/check_skill.sh      # estructura y enlaces del skill
```

## Origen

Fork del [OpenCode-Orchestrator-Skill](https://github.com/DragonJAR/OpenCode-Orchestrator-Skill) 1.0.0 de DragonJAR, reconstruido para herdr por Electronic Cats. La versión OpenCode se conserva en el tag `opencode-final`.

## Licencia

MIT, ver [SKILL/LICENSE](SKILL/LICENSE).
