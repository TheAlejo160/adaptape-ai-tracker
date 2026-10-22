# AGENTS.md — AdaptaPE AI Tracker

Guía para agentes (Codex, Claude, Gemini) que trabajen en este repo. El comportamiento esperado de cada fila está en
[README.md › Cómo debería verse cada fila](README.md#cómo-debería-verse-cada-fila); este archivo explica cómo trabajar
y qué está roto ahora.

## Proyecto

App nativa de barra de menú para macOS 14+ (SwiftUI, Swift 6 con concurrencia estricta, SwiftPM, sin dependencias).
Muestra la cuota de cada IA leyendo credenciales y registros que las propias herramientas del usuario ya guardaron en
este Mac. Textos de la interfaz en español.

- `Sources/AdaptaPEAITracker/Connectors/Connector.swift`: protocolo `UsageConnector`, `HTTP` (GET/POST, tope de tamaño,
  `SameHostRedirects`, `Retry-After`), `QuotaCache` (último dato bueno, `minInterval`, espera creciente tras 429),
  `ConnectorRegistry`. La fecha y el contador de 429 se guardan en preferencias; nunca tokens ni cuotas.
- `Connectors/CLI/*.swift`: un conector por herramienta (Claude, Codex, Gemini/Antigravity, Cursor, Copilot, OpenCode).
- `Connectors/CLI/LocalFiles.swift`: lecturas acotadas (`head` 64 KB, `tail` 256 KB), SQLite solo lectura,
  `processOutput` (binario de ruta fija, entorno mínimo, timeout), `cwd`, `activity`.
- `Connectors/CLI/ClaudeLocalQuota.swift`: respaldo acotado de los registros de Claude Desktop y LimitBar; fuente y cuenta no verificada explícitas.
- `Connectors/CLI/AntigravityQuota.swift`: ventanas agrupadas de 5 h/semanales de ambas referencias.
- `Connectors/CLI/AntigravityCLIQuota.swift`: consulta aislada y acotada de `agy /quota`; pasa por `QuotaCache` cada 5 min como máximo.
- `Auth/KeychainStore.swift`: lectura de ítems ajenos con `SecItemCopyMatching`, `LAContext.interactionNotAllowed` y protección serializada/restaurada de interacción para el llavero clásico; interacción solo desde Cuentas.
- `UsageStore.swift`: sondeo cada 120 s, coalescencia de refrescos, conserva datos si un conector lanza error.
- `QuotaHistory.swift`, `HistoryView.swift`: historial propio de porcentajes solicitado por el usuario; 35 días, último dato por hora/IA/ventana, máximo 20.000 puntos y 8 MB, sin credenciales ni identidad de cuenta. No registrar demo ni mover fechas de caché/registros históricos.
- `QuotaPlanning.swift`, `PlanningView.swift`: selección de IA para la barra, rotación 5 h/semanal y escenarios lineales de agentes; nunca sumar porcentajes de límites independientes ni presentar sesiones como agentes.
- `Model.swift`, `ProviderRow.swift`, `UsageBar.swift`, `ActiveSession.swift`: modelo y UI.

## Compilar, probar, instalar

`~/Desktop` añade atributos extendidos que hacen fallar `codesign` del bundle de tests. Usa siempre una ruta de build fuera:

```bash
swift build --scratch-path /tmp/aitracker-build
swift test --scratch-path /tmp/aitracker-build
scripts/bundle.sh install   # compila release, firma ad hoc, copia a ~/Applications y relanza
```

Logs de la app (añádelos con `os.Logger(subsystem: KeychainStore.service, category: …)`, nunca con secretos):

```bash
log show --last 10m --predicate 'subsystem == "com.thealejo.adaptapeaitracker"' --info --debug
```

## Reglas que no se negocian

- Solo lectura: nunca escribir, refrescar ni migrar credenciales o archivos de otras herramientas.
  Excepción autorizada por el usuario el 22 oct 2026: ejecutar exclusivamente `agy -p /quota --output-format json --print-timeout 30s`; `agy` puede gestionar y renovar su propia sesión. Mantener aislamiento, entorno mínimo y caché; no extender esta excepción a otras órdenes, herramientas ni escrituras directas.
- Ningún token en logs, errores, tests, salida de terminal ni disco. En pruebas manuales imprime solo nombres de campos,
  longitudes, fechas de caducidad y códigos HTTP.
- Tokens solo en cabeceras, solo hacia el host de su proveedor; mantener `SameHostRedirects`.
- Binarios con ruta absoluta fija (`/usr/bin/security`), nunca resueltos por `PATH`; entorno mínimo.
- Un fallo de red o de credencial nunca oculta las sesiones locales: el conector devuelve `ProviderUsage` con `error`.
- No golpear endpoints: toda consulta de cuota pasa por `QuotaCache`. **No llames a mano a
  `api.anthropic.com/api/oauth/usage`**: la cuenta del usuario está limitada por token (429, `retry-after: 3600`) y cada
  llamada alarga el bloqueo.
- Estilo: conciso, pocos comentarios (solo el porqué), igual que el código vecino. Cada lógica nueva con su test en
  `Tests/AdaptaPEAITrackerTests`.

## Hechos verificados en este Mac (22 oct 2026)

- Claude Code guarda su OAuth en el llavero: servicio `Claude Code-credentials`, JSON `claudeAiOauth`
  {`accessToken`, `expiresAt` (ms), `refreshToken`, `subscriptionType`, `rateLimitTier`, `scopes`}.
  `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` lo devuelve sin aviso desde la terminal.
- `agy` (Antigravity CLI, `~/.local/bin/agy`) guarda su OAuth con go-keyring: servicio `gemini`, cuenta `antigravity`,
  valor `go-keyring-base64:<base64 de JSON>` con `token.access_token` y `token.expiry` (ISO 8601 con microsegundos y zona).
  Dura 1 h y solo se renueva mientras `agy` corre. Desde la terminal, `security … -s gemini -a antigravity -w` funciona sin aviso.
- `agy` consulta `https://daily-cloudcode-pa.googleapis.com/v1internal:`:
  - `loadCodeAssist` con `{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}`
    devuelve `currentTier` (`free-tier`), `paidTier` (`g1-pro-tier`) y `cloudaicompanionProject`.
    Con `ideType: "ANTIGRAVITY"` solo devuelve `allowedTiers`.
  - `fetchAvailableModels` con `{}` devuelve `models` {id: {`displayName`, `quotaInfo`: {`remainingFraction`, `resetTime`}}}.
    proto3 omite los ceros: si hay `resetTime` sin `remainingFraction`, ese grupo está agotado (Claude/GPT-OSS en Antigravity).
- `~/.gemini/oauth_creds.json` (Gemini CLI) **no existe** en este Mac; `gemini` está instalado pero sin sesión.
- Codex: `~/.codex/auth.json` + `chatgpt.com/backend-api/wham/usage` funcionan; los registros `~/.codex/sessions/**/rollout-*.jsonl`
  traen `rate_limits` y `session_meta.payload.cwd`.

## Incidencias de la captura (22 oct 2026 00:38)

Registro del diagnóstico original. Los cambios de código y las comprobaciones posteriores se documentan en
[docs/DIAGNOSTICO-2026-10-22.md](docs/DIAGNOSTICO-2026-10-22.md). No repetir consultas manuales para reproducirlo. La mejora posterior se documenta en [la fusión funcional](docs/FUSION-REFERENCIAS-2026-10-22.md).

1. **Claude muestra "Sesión caducada: vuelve a usar la herramienta para renovarla"** (`ConnectorError.unauthorized`, que
   `HTTP` lanza ante 401/403). Al mismo tiempo el endpoint responde **429** a una petición manual con el mismo token, y
   `expiresAt` es 07:57. O la app recibe otra respuesta (403 por `User-Agent`, cabeceras o token distinto) o clasifica mal.
   Esperado: con 429, "El servidor limitó las consultas (429) · reintento en …" y la cuota anterior si la hay.
   Investiga con logs (código HTTP, origen del token y su longitud; nunca el valor) antes de cambiar nada. Distingue
   401 (token inválido, "ejecuta «claude»") de 403 (rechazo del cliente o permisos; mensaje propio).
2. **Gemini muestra "Abre «gemini» para iniciar sesión"** aunque `agy` tiene token en el llavero. Ese mensaje solo sale
   cuando `keyring == nil` y no existe `oauth_creds.json`, así que `LocalFiles.processOutput("/usr/bin/security", …)`
   devuelve nil **dentro de la app** aunque funcione en la terminal. Hipótesis por comprobar:
   - macOS atribuye el hijo `security` a la app que lo lanza (proceso responsable) y pide permiso: lo mata el timeout de 5 s.
   - Salida no UTF-8 o código de salida distinto de 0.
   - Bug en `processOutput` (lectura no bloqueante/drenaje).
   Registra estado de salida, bytes leídos y si hubo timeout. Si `security` no sirve desde la app, define el
   comportamiento: opción explícita en Cuentas (`.keychainConsent`, aviso de macOS una vez) y un mensaje que nombre a `agy`.
   La misma causa puede afectar a Claude (`KeychainStore.readForeign` cae a `SecItemCopyMatching` y macOS vuelve a preguntar).
3. Las sesiones de Gemini CLI salen como "Gemini CLI · thealejo" cuando el directorio es `$HOME`: un `cwd` igual a home
   debería mostrarse como "~" o con la hora, igual que el respaldo de Claude/Codex.

## Cómo verificar

1. `swift test --scratch-path /tmp/aitracker-build` en verde, con tests nuevos para cada arreglo.
2. `scripts/bundle.sh install` y espera unos 30 s.
3. Lee los logs (comando de arriba) y comprueba cada fila contra la tabla del README.
4. Sin acceso de Accesibilidad no puedes abrir el panel: informa de lo que muestran los logs y deja la comprobación
   visual al usuario. No cambies ajustes de seguridad ni de privacidad de macOS.
