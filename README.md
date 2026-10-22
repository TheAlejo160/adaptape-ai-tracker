# AdaptaPE AI Tracker

Widget nativo para la barra de menú de macOS que muestra, de un vistazo, cuánto te queda de cada IA que usas: límites de sesión (5 h) y semanales de Claude, ChatGPT/Codex, Cursor, GitHub Copilot, OpenCode y modelos locales como Ollama o LM Studio.

Arranca solo al encender el Mac, vive en segundo plano y en reposo usa **0 % de CPU y ~25 MB de RAM**.

<p align="center">
  <img src="docs/screenshots/panel-light.png" width="300" alt="Panel en modo claro con barras de uso por proveedor">
  <img src="docs/screenshots/panel-dark.png" width="300" alt="Panel en modo oscuro">
  <img src="docs/screenshots/accounts-dark.png" width="300" alt="Pantalla de cuentas y conexiones">
</p>

> Capturas en modo demo (datos de ejemplo).

## Qué muestra

- **En la barra de menú:** el porcentaje más alto entre todas tus IAs (`72%`). El icono cambia a advertencia desde el 85 %.
- **Por proveedor:** una barra por ventana de límite (sesión 5 h, semanal, requests premium…), en verde, naranja o rojo, con un ⚠ en estado crítico para no depender solo del color, y la cuenta atrás hasta el reinicio.
- **Actividad:** un punto que pulsa mientras la herramienta está trabajando; rojo si llegaste al límite; atenuado si no hay conexión.
- **Sesiones activas:** al expandir una fila (Claude Code, Codex, OpenCode) ves las sesiones abiertas y cuánto llevan.
- **Modelos locales:** en lugar de límites muestra VRAM usada, modelo cargado y tokens/s.

## Requisitos

- macOS 14 Sonoma o posterior (Apple Silicon o Intel).
- Swift 6: las Command Line Tools de Xcode (`xcode-select --install`) o Xcode 16+.

## Instalación

```bash
git clone https://github.com/TheAlejo160/adaptape-ai-tracker.git
cd adaptape-ai-tracker
scripts/bundle.sh install
```

El script compila en modo release, crea `AdaptaPE AI Tracker.app`, la firma localmente (ad-hoc), la copia a `~/Applications` y la abre. Aparece un medidor en la barra superior.

- **Arranque automático:** en el primer arranque la app se registra como ítem de inicio de sesión. Puedes apagarlo con el interruptor del panel. Si macOS lo bloquea, sale un botón **Aprobar** que abre *Ajustes del Sistema › General › Ítems de inicio*.
- **Actualizar:** `git pull && scripts/bundle.sh install`.
- **Solo compilar sin instalar:** `scripts/bundle.sh` (deja la app en `build/`).

### Desinstalar

1. Apaga "Abrir al iniciar sesión" en el panel y sal con ⌘Q.
2. Borra `~/Applications/AdaptaPE AI Tracker.app`.
3. Opcional: borra la caché de iconos en `~/Library/Caches/com.thealejo.adaptapeaitracker`. La app no guarda credenciales propias, así que no hay nada más que limpiar.

## Conectar tus IAs

No hay que iniciar sesión en ningún sitio. La app **detecta sola** las herramientas de IA que ya usas en tu Mac y lee la sesión que cada una guardó. Abre el panel y pulsa el icono de persona (⌘,) para ver el estado en **Cuentas**.

| Forma | Proveedores | Cómo funciona |
|---|---|---|
| **Automática** | ChatGPT (Codex), Cursor, GitHub Copilot, OpenCode, Ollama, LM Studio | Si la herramienta está instalada y con sesión iniciada, aparece sola con un ✓. Si no, queda oculta. No haces nada. |
| **Con permiso del Llavero** | Claude (Claude Code) | El token vive en el Llavero; actívalo con el interruptor y macOS pedirá permiso una vez. |
| **Variable de entorno** | OpenRouter y proveedores personalizados | La clave API se lee de una variable de entorno (p. ej. `OPENROUTER_API_KEY`). La app nunca la guarda ni te la pide por pantalla. |

> Si tienes ChatGPT/Codex o Claude Code ya activos, la app se conecta sola al arrancar: toma el mismo token que esas herramientas ya dejaron en tu Mac. Si el de Claude está caducado, la fila lo dice; ejecuta `claude` una vez y se renueva.

### De dónde sale cada dato

| Proveedor | Fuente local | A qué endpoint consulta |
|---|---|---|
| Claude | Token de Claude Code en el Llavero (`Claude Code-credentials`); sesiones en `~/.claude/projects` | `api.anthropic.com/api/oauth/usage` |
| ChatGPT | `~/.codex/auth.json`; si falla, el último registro de `~/.codex/sessions` | `chatgpt.com/backend-api/wham/usage` |
| Cursor | Sesión en `state.vscdb` (solo lectura) | `cursor.com/api/usage-summary` |
| GitHub Copilot | Token de `gh` | `api.github.com/copilot_internal/user` |
| OpenCode | `~/.local/share/opencode/opencode.db` (solo lectura) | — (solo local: sesiones, tokens y costo de hoy) |
| OpenRouter | Variable `OPENROUTER_API_KEY` | `openrouter.ai/api/v1/key` |
| Ollama | — | `127.0.0.1:11434/api/ps` |
| LM Studio | `lms ps --json` | `127.0.0.1:1234/api/v0/models` |

Los datos se actualizan cada 2 minutos, al abrir el panel si tienen más de 1 minuto, y justo después de que el Mac despierta. El token se lee en cada actualización y se usa solo en memoria.

### Modo demo

En **Cuentas › Modo demo** ves la interfaz completa con datos de ejemplo, sin conectar nada.

## Añadir cualquier IA sin programar

Crea `~/Library/Application Support/AdaptaPE AI Tracker/providers.json` con un endpoint y un icono. Ejemplo completo en [`examples/providers.json`](examples/providers.json):

```json
[
  {
    "id": "deepseek",
    "name": "DeepSeek",
    "kind": "cloud",
    "icon": "deepseek",
    "url": "https://api.deepseek.com/user/balance",
    "headers": { "Authorization": "Bearer {{env:DEEPSEEK_API_KEY}}" },
    "summary": "Saldo: {balance_infos.0.total_balance} {balance_infos.0.currency}"
  }
]
```

- `kind`: `cloud`, `codeAssistant` o `local`.
- `icon`: un nombre de [lobe-icons](https://lobehub.com/icons) o una URL a un SVG/PNG.
- `headers`: `{{env:NOMBRE}}` se sustituye por esa variable de entorno (donde pones tu clave). Si la variable no existe, el proveedor queda oculto. La app no guarda la clave.
- `windows`: barras de límite. Cada una tiene `label`, `used` (ruta JSON con puntos; los números indexan arrays), `limit` opcional, `scale` (`ratio` = used/limit, `percent` = 0–100, `fraction` = 0–1), `resetsAt` y `detail` (plantilla con `{used}` y `{limit}`).
- `summary`: una línea de texto con `{ruta.json}`.

Reinicia la app para cargar los cambios. Si un `id` coincide con uno incluido, se ignora.

## Privacidad y seguridad

Diseñada para no guardar nada y funcionar en local:

- **La app no almacena credenciales propias.** No escribe tokens ni claves en disco, Llavero, `UserDefaults` ni logs. Solo **lee** lo que otras herramientas ya guardaron, en cada actualización, y lo usa en memoria.
- **Sin login web.** No hay ventana de inicio de sesión ni cookies: eso evita el lío del passkey y no deja rastro.
- Los tokens solo viajan hacia el propio proveedor, en cabeceras HTTP, con una sesión efímera (sin caché ni tarro de cookies). Si un servidor redirige a otro dominio, la petición se **corta** para que ningún token salga a un host ajeno.
- El Llavero se abre en **solo lectura** y únicamente para el proveedor que actives (Claude). Las bases de datos de otras apps (Cursor, OpenCode) también se abren en solo lectura. La app nunca escribe en archivos de otras herramientas.
- Las claves de API (OpenRouter, personalizados) se leen de variables de entorno; nunca se piden por pantalla ni se guardan.
- No hay telemetría ni servidor propio. Todo ocurre en tu Mac.

> **Aviso:** Claude, ChatGPT, Codex y Cursor no tienen API pública de límites. Esta app usa los mismos endpoints internos que sus propias apps, que pueden cambiar sin aviso. No está afiliada con Anthropic, OpenAI, Cursor, GitHub ni ningún otro proveedor. Úsala con tus propias cuentas.

## Cómo está hecho

SwiftUI nativo (`MenuBarExtra`), Swift 6 con concurrencia estricta y sin dependencias externas.

```
Sources/AdaptaPEAITracker/
├── AdaptaPEAITrackerApp.swift   MenuBarExtra + etiqueta con el % máximo
├── UsageStore.swift             Estado global (@Observable), polling, cuentas activas
├── Model.swift                  ProviderInfo, ProviderUsage, UsageWindow, Activity…
├── PanelView.swift / ProviderRow.swift / UsageBar.swift / ActiveSession.swift / AccountsView.swift
├── ProviderIcon.swift           Iconos SVG con caché en memoria y disco
├── LoginItem.swift              Arranque al iniciar sesión (SMAppService)
├── Auth/                        KeychainStore (solo lectura de ítems de otras apps)
└── Connectors/
    ├── Connector.swift          Protocolo UsageConnector, HTTP (corte de redirección entre hosts), registro
    ├── CLI/                     Claude, ChatGPT, Cursor, Copilot, OpenCode (lectura de credenciales locales)
    ├── LocalConnectors.swift    Ollama, LM Studio
    ├── OpenRouterConnector.swift
    ├── CustomConnector.swift    Proveedores definidos en providers.json
    └── MockConnector.swift      Modo demo
```

### Añadir un conector en código

1. Crea un `struct` que cumpla `UsageConnector`:

   ```swift
   struct MiIAConnector: UsageConnector {
       let info = ProviderInfo(id: "mi-ia", name: "Mi IA", kind: .cloud,
                               iconURL: ProviderInfo.lobeIcon("mi-ia"), auth: .apiKeyEnv("MI_IA_API_KEY"))

       func fetch() async throws -> ProviderUsage? {
           guard let key = ProcessInfo.processInfo.environment["MI_IA_API_KEY"], !key.isEmpty else { return nil } // no configurado → oculto
           // … HTTP.getJSON(…) y rellenar un ProviderUsage(info: info)
       }
   }
   ```

2. Añádelo a `ConnectorRegistry` en `Connectors/Connector.swift`.

Si `fetch()` devuelve `nil`, el proveedor se oculta. Si lanza un error, el panel mantiene los últimos datos y muestra el error en naranja.

### Accesibilidad y rendimiento

- Etiquetas de VoiceOver en cada fila y control; respeta *Reducir movimiento*; contraste correcto en modo claro y oscuro.
- Atajos: ⌘R actualizar, ⌘, cuentas, ⎋ volver, ⌘Q salir.
- Las animaciones se detienen mientras el panel está cerrado: `MenuBarExtra` mantiene viva la vista oculta y, si no, seguirían gastando CPU.

## Créditos

- Lógica de lectura de límites inspirada en [vzandli/GaugeZ](https://github.com/vzandli/GaugeZ) y [dancik/limitbar](https://github.com/dancik/limitbar).
- Iconos: [lobe-icons](https://github.com/lobehub/lobe-icons) (MIT) y [simple-icons](https://github.com/simple-icons/simple-icons) (CC0). Las marcas pertenecen a sus dueños.

## Licencia

[MIT](LICENSE)
