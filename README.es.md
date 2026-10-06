# herdr-orchestrator

[![Licencia](https://img.shields.io/badge/licencia-MIT-blue.svg)](SKILL/LICENSE)
[![Versión](https://img.shields.io/badge/versi%C3%B3n-0.1.0-green.svg)](SKILL/SKILL.md)
[![Plataforma](https://img.shields.io/badge/plataforma-herdr-8A2BE2.svg)](https://herdr.dev)
[![English](https://img.shields.io/badge/read%20in-English-blue.svg)](README.md)

> Pídele a Claude, dentro de [herdr](https://herdr.dev), que reparta una tarea grande entre varios agentes de código. Él abre los panes, reparte el trabajo, espera, comprueba cada resultado con evidencia escrita y te entrega un resumen corto.

## Qué es

Un skill de Claude Code. Sigues hablando con Claude en tu pane de herdr como siempre; cuando una tarea vale la pena repartirla, Claude se vuelve el **orquestador**:

- arranca **workers** en panes hermanos de tu tab: `claude`, `codex`, `opencode` o cualquier otro tipo que soporte herdr;
- cada worker recibe un archivo de tarea completo y autocontenido, y una carpeta donde puede escribir;
- Claude nunca hace el trabajo él mismo ni lee las transcripciones completas de los workers, solo sus reportes cortos, así su propio contexto se mantiene pequeño;
- una tarea solo cuenta como terminada cuando el archivo de evidencia del worker demuestra el criterio de aceptación.

## Cómo se usa

Solo pídelo con tus palabras:

> *Orquesta dos workers en herdr: uno documenta `src/a` y otro documenta `src/b`.*

> *Reparte este refactor entre un worker claude y uno codex en herdr y verifica cada resultado.*

Lo que vas a ver:

1. Aparecen dos panes junto al tuyo, con etiquetas `[01] Vermithrax`, `[02] Pyreclaw`… (los nombres por defecto salen de un catálogo de dragones).
2. Cada worker recibe su tarea y empieza a trabajar; puedes mirarlos o ignorarlos.
3. Si un worker se detiene a pedir una aprobación, Claude te dice qué pane te necesita y suena una notificación de herdr. **Tú** la respondes; Claude nunca lo hace.
4. Cuando todo está comprobado, Claude responde con un reporte corto: qué hizo cada worker, si su evidencia pasó y qué requiere tu atención.
5. Los panes de los workers siguen abiertos hasta que le pidas a Claude que los cierre.

## Cómo funciona por dentro

```
tu pane (Claude, orquestador)
        |   orch.sh  (SKILL/scripts)
        v
  CLI de herdr  --->  pane [01] worker   pane [02] worker   ...
        |
        v
.herdr-orch/<run>/            (dentro de tu proyecto, ignorado por git)
    ledger.yaml               cada tarea, su worker y su estado
    workers.tsv               qué agente vive en qué pane
    <task>/prompt.md          el archivo de tarea que lee el worker
    <task>/report.md          el reporte corto del worker (≤500 palabras)
    <task>/evidence.yml       criterio · resultado · qué se comprobó
```

Una corrida pasa por seis pasos:

1. **Repartir** el pedido en tareas, cada una con un criterio y los archivos que puede tocar. Las tareas que escribirían los mismos archivos se ponen en orden en vez de correr en paralelo.
2. **Arrancar workers** en panes hermanos (`init-run`). Si un pane no arranca, volver a correrlo completa solo lo que falta.
3. **Enviar** a cada worker su tarea (`dispatch`): una línea corta que apunta a su archivo de tarea.
4. **Esperar** a cada worker (`wait`). Las aprobaciones van a ti; un worker que desaparece, se cuelga o cuyo resultado es incierto se reporta, nunca se reintenta en silencio.
5. **Verificar** cada reporte y su evidencia (`verify`).
6. **Cerrar** la corrida (`close`): un validador revisa todo el registro e imprime `TOTAL: N passed, 0 failed`.

## Garantías

- **Nunca responde por ti.** Las aprobaciones y el diálogo de confianza de carpeta de Claude siempre te los deja a ti.
- **Nunca reenvía a ciegas.** Si no está claro si un worker recibió su tarea, Claude primero reconcilia (`reconcile`) y solo la reenvía si está probado que nunca llegó.
- **Solo toca lo que creó.** Cerrar panes o worktrees afecta solo a los workers de esta corrida, nunca a tu pane ni a nada más, y solo cuando tú lo pides.
- **Ningún resultado sin evidencia.** "El agente quedó inactivo" no es éxito; solo lo es una evidencia que pasa la verificación.
- **Se queda en herdr.** Fuera de un pane de herdr solo propone un plan; no finge haber ejecutado nada.

## Diferencias con el original

Este repo es un fork de [OpenCode-Orchestrator-Skill](https://github.com/DragonJAR/OpenCode-Orchestrator-Skill) 1.0.0 de DragonJAR, pero hace otro trabajo:

| | OpenCode-Orchestrator-Skill | herdr-orchestrator |
| --- | --- | --- |
| Runtime | Servidor OpenCode V2 (API HTTP) | Multiplexor de terminal herdr (CLI) |
| Workers | Sesiones de OpenCode, cada una con ≥2 subagentes nativos | Agentes de cualquier tipo en panes hermanos; sus subagentes internos son asunto suyo |
| Ver el trabajo | Tabs de la TUI de OpenCode parchadas | Panes reales de herdr, con etiqueta `[NN] Nombre` |
| Registro | YAML schema 3 (sesiones, `parentID`, ubicaciones) | YAML schema 4 (agente, pane, worktree, evidencia de entrega) |
| Aislamiento | Scopes de escritura disjuntos | Scopes disjuntos, o un worktree de git por worker si lo pides |
| Se conservó del original | — | Orquestador que nunca implementa, prompts de tarea completos, compuerta de evidencia escrita, validadores POSIX, reglas fail-closed, nombres de dragón |
| Se eliminó | — | Descubrimiento HTTP/autenticación, parche de tabs, adaptadores por sistema operativo, la regla de dos subagentes |

La versión de OpenCode se conserva en el tag `opencode-final`.

## Instalación

El nombre de la carpeta debe ser igual al nombre del skill, `herdr-orchestrator`.

```bash
git clone https://github.com/sabas1080/herdr-orchestrator.git ~/.claude/skills/herdr-orchestrator-src
ln -s ~/.claude/skills/herdr-orchestrator-src/SKILL ~/.claude/skills/herdr-orchestrator   # o copia SKILL/ ahí
```

| Requisito | Versión |
| --- | --- |
| herdr | ≥ 0.8.2 — Claude debe correr dentro de un pane de herdr (`HERDR_ENV=1`) |
| jq | cualquier versión reciente |
| `sh` + `awk` POSIX | para `orch.sh` y los validadores |
| git | solo para el modo opcional con worktrees |

## Dejar que los workers trabajen solos

Por defecto los workers arrancan en tu modo de permisos normal, así que un worker Claude se detiene cada vez que quiere editar un archivo o correr un comando, y te espera. Si quieres que trabajen solos, dile a Claude en qué modo arrancarlos; él pasa argumentos nativos con `--agent-arg`:

```sh
orch.sh init-run --worker claude --worker claude --agent-arg --permission-mode --agent-arg auto
```

Hazlo solo cuando de verdad quieras workers sin supervisión. Además, una carpeta que Claude nunca ha visto (un repo nuevo o un worktree) muestra una vez el diálogo de confianza de carpeta de Claude; respóndelo en ese pane y pídele a Claude que continúe: vuelve a correr `init-run` con las mismas opciones.

## Para desarrolladores

Toda la mecánica vive en `SKILL/scripts/orch.sh` (POSIX sh, necesita `herdr` + `jq`). Claude lo ejecuta desde la raíz del proyecto; normalmente tú no.

```
orch.sh preflight
orch.sh init-run [--run-id ID] --worker KIND[:Title]... [--worktree] [--agent-arg ARG]...
orch.sh pool [--run ID]
orch.sh task add --id ID --worker NAME|NN --criterion TEXT --scope A[,B] [--deps X[,Y]] [--run ID]
orch.sh task set --task ID --estado cancelled|failed|partial|blocked|interrupted --notas TEXT [--run ID]
orch.sh dispatch --task ID --prompt-file F [--wait] [--timeout MS] [--run ID]
orch.sh wait --task ID [--timeout MS] [--stuck-secs N] [--run ID]
orch.sh reconcile --task ID [--run ID]
orch.sh verify --task ID [--run ID]
orch.sh suggest-count FILE
orch.sh close [--allow-degraded] [--run ID]
orch.sh teardown [--confirm] [--remove-worktrees] [--run ID]
```

Códigos de salida: `0` ok · `1` falla · `2` uso/entorno · `3` resultado incierto/timeout · `4` colgado (aviso) · `5` esperando tu aprobación.
Las instrucciones del skill están en [SKILL/SKILL.md](SKILL/SKILL.md); los detalles, en [SKILL/references/](SKILL/references/).

### Pruebas

```sh
sh tests/run_validators.sh   # validadores del registro
sh tests/run_orch.sh         # orch.sh contra un herdr falso (se pone su propio tope de memoria)
sh tests/check_skill.sh      # estructura y enlaces del skill
```

Las pruebas nunca tocan tu sesión de herdr. Una corrida real contra herdr 0.8.2 con dos workers `claude` quedó registrada en [docs/superpowers/acceptance/2026-10-06-e2e.md](docs/superpowers/acceptance/2026-10-06-e2e.md): ambas tareas verificadas, `TOTAL: 4 passed, 0 failed`.

## Origen y licencia

Original de [DragonJAR](https://github.com/DragonJAR/OpenCode-Orchestrator-Skill); reconstruido para herdr por Electronic Cats. MIT, ver [SKILL/LICENSE](SKILL/LICENSE).
