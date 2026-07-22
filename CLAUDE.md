# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Create Layer** is a QField plugin (QML/JavaScript, single `main.qml`) for field data collection: create GeoJSON layers directly in the field, register them in the project legend (TOC), digitize features, and export/share data. Developed for and tested on iOS (QField ≥ 3.2); originally spun off from the `enzococca/nilgiri_deforestation` project.

**UI language:** bilingual. Every UI string goes through the `tx(en, it)` helper — English by default, Italian when the device locale starts with `it`. QML method names MUST start lowercase (a helper named `T()` broke plugin loading entirely).

## Build & Release

```bash
python package.py     # builds createlayer.zip + releases/<version>/createlayer.zip
```

- The ZIP must contain `main.qml`, `metadata.txt`, `icon.svg` at its ROOT (QField requirement). The zip filename becomes the plugin folder name on the device — never version the filename itself.
- Release flow: edit `main.qml` → bump `version=` in `metadata.txt` → update the version string in `diagnosticsReport()` → `python package.py` → commit everything (including `releases/<version>/`) → push to `main`.
- Install URLs (QField → Settings → Plugins → Install from URL):
  - versioned (cache-proof, preferred): `https://github.com/enzococca/createlayer/raw/main/releases/<version>/createlayer.zip`
  - latest (may be served stale by GitHub's CDN for a few minutes): `https://github.com/enzococca/createlayer/raw/main/createlayer.zip`
- If the device keeps an old version: uninstall plugin, force-quit QField, reinstall (QML stays cached while the app is alive). Manual removal: iOS Files app → QField → `plugins/createlayer`.

There is no test suite. XML-injection and template logic were validated by mirroring the JS functions in Python (ElementTree well-formedness + structural assertions); repeat that pattern when touching `injectLayerXml`/`projectTemplate`.

## Architecture (main.qml)

Single root `Item` with all logic as JS functions. Key subsystems, in file order:

1. **I/O self-test (`ensureIo`)** — run once per project (on plugin button tap, via `loadIndex`). Writes a probe file and determines:
   - `writeMode`: `string` | `buffer` | `broken` — write correctness is verified via MD5 (`FileUtils.getFileInfo().md5`) against a precomputed constant, because reads may lie.
   - `readMode`: `bytes` | `fileinfo` | `xhr` | `broken` — first channel whose round-trip returns the probe content.
   All app writes go through `writeText()` (manual UTF-8 `strToBuffer()` when `writeMode==='buffer'`); all reads through `readText()`.
2. **Layer index** — `layerIndex` (array of `{name, file, geometry, fields, created, featureCount, layerId, inProject}`), persisted to BOTH `qfield_layers/index.json` AND the project variable `createlayer_index` (via `ExpressionContextUtils.setProjectVariable` in memory, and embedded in the `.qgs` `<properties><Variables>` block by `writePluginProject`). `loadIndex` falls back to the project variable when the file is unreadable.
3. **Layer creation** — writes a GeoJSON FeatureCollection (EPSG:4326, CRS84) under `<project home>/qfield_layers/`. Layers with fields get a **template feature with null geometry** (defines OGR field types; `integer`→1, `number`→0.1, `date`→'2000-01-01', `string`→''); only written in TOC mode.
4. **TOC registration** — for plugin-generated projects (`isPluginProject()`: path contains `/createlayer_projects/` or file is `starter_project.qgs`), the whole `.qgs` is **rewritten from scratch** by `writePluginProject()` (template + `injectLayerXml` per layer + index in Variables) — no reads needed. For foreign `.qgs` projects, read–modify–write with `.createlayer.bak` backup. After writing: `iface.reloadProject()`.
5. **Project creation** — `createProject()` writes a new `.qgs` in `createlayer_projects/<slug>/` INSIDE the current project dir (see sandbox below), then `iface.loadFile()`. With no project open, `iface.importUrl(starterProjectUrl, name, true)` downloads `starter_project.qgs` from this repo.
6. **Integrated digitizing** — fallback for layers not in the TOC (e.g. `.qgz` projects): floating panel, vertices from GPS (`positionSource.projectedPosition` reprojected via `GeometryUtils.reprojectPointToWgs84`) or map center (`mapSettings.screenToCoordinate`), attribute dialog per feature, JSON appended via `commitFeature`.
7. **Export** — per layer: `platformUtilities.exportDatasetTo` (save-as), `sendDatasetTo` (share), CSV with WKT geometry; global: `sendCompressedFolderTo(layersDir())` ("Layers ZIP") and `sendCompressedFolderTo(homePath())` ("Project ZIP", includes the `.qgs`).
8. **Diagnostics** — `diagnosticsReport()` (button in main dialog): io modes, paths, read/parse status of project/index/layers, `lastError` (set by `setError()` at every failure point), copy-to-clipboard. This report was the primary remote-debugging tool during development — keep it exhaustive.

## Hard-won constraints (do not regress)

- **QField write/read sandbox**: `FileUtils.writeFileContent`/`readFileContent` refuse any path OUTSIDE the current project's directory (`isWithinProjectDirectory` in QField's fileutils.cpp). With no project open, nothing is writable. This is why new projects nest inside the current project's folder.
- **Broken QByteArray↔JS bridge on iOS builds**: reads may return correct length but NUL content; JS-string writes may corrupt too. Never trust a read round-trip — that's what the io self-test is for. `getFileInfo().md5` and project variables arrive as clean QStrings and are the reliable side-channels.
- **QML API surface** (verified against QField source): no `addLayer` API — TOC integration is done by writing project XML + `reloadProject()`. `QgsProject.write()` is NOT invokable from QML. `.qgz` cannot be modified (no zip API).
- **Projects must be EPSG:3857** (template `projectTemplate()`): with a 4326 project CRS the OSM XYZ basemap is rewarped every redraw and vectors appear to drift during pan/zoom. Layers stay EPSG:4326 with an explicit full `<srs>` block in the injected `<maplayer>` (a missing srs made layer CRS invalid → unstable rendering).
- **`|geometrytype=Point|LineString|Polygon`** suffix on the OGR datasource forces the geometry type of still-empty GeoJSON layers.
- **QGIS CRS XML**: `readXml` resolves `<authid>` first (verified in QGIS source), so the minimal `spatialrefsys` blocks (`authid` + `proj4` + srsid) are sufficient.
- **Dialogs**: override `implicitWidth`/`implicitHeight` with window-derived values only — Material Dialog's content-derived implicit size causes binding loops.
- Date/number parsing, XML escaping (`xmlEscape`) and the manual UTF-8 encoder (`strToBuffer`) are all local — QField's JS engine (V4) has no `TextEncoder`/`TextDecoder`.

## Version history (summary)

- 1.0 GeoJSON layers + integrated digitizing + export/share/CSV
- 1.1 TOC registration by editing `.qgs` + reloadProject; dialog binding-loop fix
- 1.2 In-plugin project creation (`loadFile`)
- 1.3 Respect write sandbox (project created inside current project; starter via `importUrl`); verified writes
- 1.4 Guided field editor (name + type combobox)
- 1.5 Resilient digitizing, diagnostics button, integer field type; project rebuild for plugin projects
- 1.6 Adaptive io self-test (string vs UTF-8 buffer writes, md5-verified)
- 1.7 Alternative read channels (getFileInfo / sync XHR)
- 1.8 Explicit `<srs>` on injected layers; index persisted as project variable; full project rewrite for plugin projects
- 1.9 Project template in EPSG:3857 (fixes vector/basemap drift)
- 1.10 "To legend" retry button + `lastError` tracking
- 1.11 Bilingual UI (`tx()` — renamed from `T()`, uppercase broke QML), Layers ZIP / Project ZIP, versioned release URLs
