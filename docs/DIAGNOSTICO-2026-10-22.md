# Diagnóstico de la captura del 22 de octubre de 2026

> Informe de la primera revisión. La [fusión funcional posterior](FUSION-REFERENCIAS-2026-10-22.md) actualiza la presentación de ventanas, los respaldos locales y la persistencia de la espera de 429.

Se conservaron y terminaron los cambios interrumpidos de la sesión anterior. No se modificaron credenciales de otras herramientas ni ajustes de seguridad o privacidad de macOS.

## Hallazgos y cambios

### Claude: caducidad, rechazo y límite de consultas son estados distintos

La captura no permite conocer qué respuesta recibió el ejecutable antiguo: no había trazas HTTP recuperables de esa ejecución. El diagnóstico original de AGENTS.md describe una clasificación compartida de 401 y 403. La versión actual distingue 401, 403 y 429 y registra host, código HTTP, origen, longitud del token y caducidad; nunca el token.

La ejecución instalada a las 00:50 confirmó una lectura de Claude con `interactive=false`, `status=0`, seguida de HTTP **429**, con `Retry-After: 2938`. Por tanto, esa consulta real está limitada por el proveedor; no indica que el token haya caducado. No se hicieron peticiones manuales a su endpoint.

`QuotaCache` conserva la última cuota de las mismas credenciales y muestra su antigüedad. Respeta `Retry-After` y aplica espera creciente tras 429. Se corrigió además un fallo reproducido por pruebas: 401, 403 y errores de red no respetaban el intervalo mínimo entre intentos. Ahora también se espacian, conservando su causa real. Un token caducado conserva la cuota previa de esas credenciales; un cambio de credenciales de Gemini no reutiliza la cuota anterior.

### Gemini / agy: lectura explícita del llavero

La lectura mediante un hijo `/usr/bin/security` no es una garantía de acceso desde la app. No se pudo establecer retrospectivamente si el fallo de la captura fue un timeout, un código de salida o una restricción de acceso. El drenaje de procesos tiene diagnósticos y pruebas para salida rápida, código de error, tamaño máximo y timeout.

La app usa ahora `SecItemCopyMatching`. En Cuentas, Gemini ofrece un permiso opcional para el llavero de `agy`; apagarlo conserva la detección de archivos y las sesiones locales. Solo la acción explícita del usuario permite interacción. Si falla la lectura, el mensaje nombra a `agy` y explica cómo pedir permiso, sin inventar una caducidad ni ocultar sesiones.

Se usa `LAContext.interactionNotAllowed` y, para el llavero clásico de macOS, el control de interacción de Security limitado al proceso. Este control está protegido por un bloqueo y restaura el valor anterior incluso si la operación lanza un error. **No modifica permisos del ítem, ACL, contraseñas ni ajustes de macOS.** Las API `SecKeychain…` producen advertencias de deprecación deliberadas: los controles modernos no cubren ese llavero clásico.

Referencias primarias: [LAContext y consulta de llavero](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext), [control de interacción de Security](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:)), [implementación de Chromium y limitación del llavero clásico](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc).

### Sesiones en la carpeta personal

`LocalFiles.projectName` trata la carpeta personal normalizada como ausencia de nombre de proyecto. Gemini utiliza la hora de creación (`Gemini CLI · HH:mm`) en ese caso, igual que los respaldos de Claude y Codex. Las pruebas incluyen `$HOME`, barra final y `/.`.

## UX y alcance

Evaluación inicial de la captura: **5/10**, limitada a la superficie mostrada. Fallan visibilidad del estado (severidad 3), diagnóstico y recuperación de errores (3), y reconocimiento de sesiones (2). Se descuentan 2, 2 y 1 puntos respectivamente; búsqueda y navegación general no se valoran con esta captura.

Los errores ya no se cortan a dos líneas: la instrucción de recuperación permanece legible. Se evita duplicar «Sin datos» junto al error y se elimina la atenuación de toda la fila cuando está desconectada. Los interruptores del llavero tienen un nombre accesible explícito.

Se mantiene `MenuBarExtra` con materiales del sistema y compatibilidad con macOS 14. No se añadieron capas decorativas de vidrio, dependencias ni una nueva jerarquía de clases. El protocolo de conectores, el actor de caché y el estado observable existente cubren este arreglo.

No se asigna una puntuación final de 10/10 sin comprobar el panel real, teclado, VoiceOver y contraste en ambos temas. La automatización de la app instalada devolvió timeout; no se cambiaron permisos de Accesibilidad para sortearlo.

## Validación

- `swift test --scratch-path /tmp/aitracker-build`: **28 pruebas en verde**. Cubren 401/403/429, esperas y conservación de cuotas, credenciales caducadas, separación de credenciales, sesiones locales, `$HOME`, consultas no interactivas, restauración del estado de interacción y procesos acotados.
- Las dos pruebas nuevas de intervalo mínimo fallaron antes de corregir `QuotaCache` y pasan después.
- `zsh -n scripts/bundle.sh`: correcto. El script compila fuera de Desktop para evitar los atributos extendidos en artefactos de SwiftPM.
- Detector de Impeccable para las dos vistas modificadas: sin hallazgos. Esto no sustituye una inspección visual nativa.
- La primera instalación release se ejecutó y su bundle en `~/Applications` pasó `codesign --verify --strict`. Su ejecutable coincidió con el compilado. La copia de `build/` recibió de nuevo atributos de Desktop y falló esa comprobación posterior; el bundle instalado sí pasó.
- La versión final se instaló y relanzó a las 00:55. Su bundle pasó `codesign --verify --strict`. Claude devolvió `interactive=false`, `status=-25293`, `bytes=0`: acceso al llavero rechazado tras el cambio de firma, sin consultar su endpoint. La fila pide autorizar el Llavero en Cuentas, no renovar un supuesto token caducado. ChatGPT, Cursor y Copilot devolvieron HTTP 200.
- Las preferencias existentes tienen solo Claude habilitado para llavero; el modo demo está apagado. No se activó Gemini automáticamente ni se solicitó su autorización durante la revisión.

## Comprobación que requiere al usuario

En **Cuentas**, desactiva y activa Claude para solicitar autorización de la nueva firma. Después activa el acceso al llavero de Gemini para leer `agy` y responde al aviso de macOS si aparece. Si ya está activado pero falla, desactívalo y actívalo. Comprueba plan, barras y sesiones. La cuota real de `agy` no se validó con ese permiso desactivado.

Claude puede seguir mostrando 429 hasta el reintento indicado. La app no puede eliminar el bloqueo del proveedor. La caché es de memoria y se pierde al reiniciar; evita relanzar repetidamente durante el bloqueo. Una actualización con firma ad hoc puede requerir autorización del llavero de nuevo.
