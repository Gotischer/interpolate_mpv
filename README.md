# MPV Interpolation Wizard

[![Latest release](https://img.shields.io/github/v/release/Gotischer/interpolate_mpv?label=descargar&color=brightgreen)](https://github.com/Gotischer/interpolate_mpv/releases/latest)
[![License](https://img.shields.io/github/license/Gotischer/interpolate_mpv)](LICENSE)

Asistente automatizado para instalar interpolación de frames en [mpv](https://mpv.io)
usando **VapourSynth + RIFE (TensorRT)** o **MVTools** como respaldo. Convierte
videos a 24/30 fps en reproducción fluida a 60/120/144 Hz.

## Descargar

Solo necesitas **un archivo**: descárgalo desde la última release.

**[➜ Descargar MPV-Interp-Wizard.bat](https://github.com/Gotischer/interpolate_mpv/releases/latest)**

Doble clic y listo. No requiere instalación previa de PowerShell ni dependencias.

## Características

- Detecta automáticamente la GPU y elige el mejor backend:
  - **NVIDIA RTX 20/30/40/50** → RIFE con TensorRT (calidad alta)
  - **AMD / Intel / GTX antigua** → MVTools (CPU, calidad básica)
- Menús con flechas (PowerShell 7+) o numéricos como respaldo.
- Acciones: instalar, actualizar, reparar, diagnóstico, desinstalar.
- Aviso automático cuando hay versiones nuevas de **vs-mlrt**, **VapourSynth** o
  del propio asistente (consulta GitHub con caché de 24 h).
- Versionado del `interpolation.vpy` con respaldo automático antes de regenerar.
- Log automático en `mpv-interp-wizard.log` para diagnóstico.

## Requisitos

- Windows 10 o superior.
- mpv ya instalado (en cualquier carpeta; el asistente lo detecta).
- ~7 GB libres en disco para el backend RIFE.
- Driver NVIDIA reciente si quieres usar RIFE.

## Cómo se usa

1. Descarga `MPV-Interp-Wizard.bat` desde la [última release](https://github.com/Gotischer/interpolate_mpv/releases/latest).
2. Doble clic. Si SmartScreen lo bloquea, haz clic en **"Más información" → "Ejecutar de todas formas"**.
3. La primera vez verás una pantalla de bienvenida y se te preguntará dónde instalar.
4. Elige **"Instalar"** en el menú principal. Tomará entre 10 y 30 minutos según tu conexión.
5. Abre cualquier video con mpv. Si tu monitor es de 120/144 Hz, lo verás fluido automáticamente.

## ¿Tengo mpv ya configurado a mano?

Sin problema. El asistente **no sobrescribe** archivos existentes (`interpolation.vpy`,
`auto_mode.lua`, `set_display_hz.ps1`). Si quieres revisar su estado sin instalar nada,
ejecútalo y elige la opción **"Diagnóstico"** en el menú.

Para regenerar el `interpolation.vpy` con la versión más reciente del template, usa
**"Actualizar → Regenerar interpolation.vpy"**. Se hace un respaldo a `interpolation.vpy.bak`
automáticamente antes de reescribir.

## Verificar la descarga

Cada release publica un archivo `SHA256.txt`. Para verificar la integridad del `.bat`:

```powershell
Get-FileHash MPV-Interp-Wizard.bat -Algorithm SHA256
```

Compara el resultado con el contenido de `SHA256.txt`.

## Estructura del repositorio

```
mpv-interp-wizard.ps1            # Asistente principal (PowerShell)
build-single-bat.ps1             # Genera el .bat auto-extraíble
LEEME.txt                        # Manual corto para usuarios finales
.github/workflows/release.yml    # CI: build + release al pushear un tag v*
```

## Publicar una versión nueva (mantenedor)

```powershell
git tag v1.0.1
git push origin v1.0.1
```

GitHub Actions construye el `.bat`, calcula el SHA256 y publica la release con los
tres archivos adjuntos. El número de versión dentro del asistente se sincroniza
automáticamente con el tag.

## Reportar problemas

Abre un [issue](https://github.com/Gotischer/interpolate_mpv/issues) e incluye el
archivo `mpv-interp-wizard.log` (queda al lado del `.bat` después de ejecutarlo).

## Licencia

[MIT](LICENSE)
