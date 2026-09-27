<p align="center">
  <img src="docs/icon.png" width="128" alt="Ollama GUI icon">
</p>

<h1 align="center">Ollama GUI</h1>

<p align="center">
  A native macOS app to manage your <a href="https://ollama.com">Ollama</a> models.<br>
  Browse, pull, update, inspect, load, customize and test models — without the terminal.
</p>

<p align="center">
  <a href="https://github.com/Hugo291/ollama-gui/releases/latest"><b>Download</b></a> ·
  <a href="#features">Features</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="#français">Français</a>
</p>

![Models](docs/screenshots/models.png)

## Features

**Models**
- Every installed model with its size, parameters, quantization, capabilities (vision, tools, thinking, embedding, image, audio) and cloud/local origin — sortable, searchable, filterable.
- Inspector with the full configuration: parameters, system prompt, template, Modelfile, license, model info and tensors.
- **Update check** against the Ollama registry (compares manifest digests, nothing is downloaded) and one-click update of one or all outdated models.
- Duplicate, rename, **customize** (new model on top of an existing one with its own system prompt, temperature, context window, top P, seed) and delete.

**Downloads & library**
- Pull any model (`gemma3`, `qwen3:8b`, `hf.co/…`) with live progress, speed and time remaining; cancel and retry.
- **Discover** the ollama.com library: search, filter by capability, sort by popularity or date, browse every tag with its size and context window, and pull in one click.

**Memory**
- Loaded models with memory used, CPU/GPU split, context size and a countdown to unload.
- Load, unload or keep a model loaded longer. Models are never pinned in memory forever: the app always sends a finite keep-alive (5 minutes by default, 1 minute to 1 hour in Settings).

**Playground**
- Streaming chat to try a model, with tokens per second, token count and load time.
- Reasoning output for thinking models, image attachments for vision models, system prompt, temperature and context window.

**And also**
- Several Ollama servers (this Mac, a machine on your network, a remote host) with a quick switcher.
- Menu bar item with loaded models and active downloads.
- English and French.

| Running models | Discover | Playground |
| --- | --- | --- |
| ![Running](docs/screenshots/running.png) | ![Discover](docs/screenshots/discover.png) | ![Playground](docs/screenshots/playground.png) |

## Install

1. Install and start [Ollama](https://ollama.com/download).
2. Download `OllamaGUI-x.y.z.zip` from the [latest release](https://github.com/Hugo291/ollama-gui/releases/latest), unzip it and move **Ollama GUI** to your Applications folder.
3. The app is signed ad hoc, not notarized: the first time, right-click it and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/Ollama GUI.app"
```

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

## Build from source

```bash
git clone https://github.com/Hugo291/ollama-gui.git
cd ollama-gui
scripts/build-app.sh
```

This builds a universal `dist/Ollama GUI.app` and `dist/OllamaGUI-<version>.zip`. Use `ARCHS=arm64 scripts/build-app.sh` for a faster Apple silicon-only build.

Run the unit tests and the localization check:

```bash
scripts/test.sh
```

Xcode is not required: the Swift toolchain of the Command Line Tools is enough. Since the macOS 27 SDK, SwiftUI's `@State` is a macro whose compiler plugin only ships with Xcode, so with the Command Line Tools alone the scripts automatically build against the newest installed SDK that doesn't need it (`scripts/sdk.sh`).

## How it works

- Everything goes through the [Ollama REST API](https://docs.ollama.com/api) of the selected server (`/api/tags`, `/api/ps`, `/api/show`, `/api/pull`, `/api/create`, `/api/copy`, `/api/delete`, `/api/chat`).
- **Updates**: the digest of a local model is the SHA-256 of its manifest. The app asks `registry.ollama.ai` for the digest of the current manifest (a `HEAD` request) and compares.
- **Discover**: ollama.com has no public search API, so the app reads its public search and tags pages. If the site layout changes, Discover may show fewer details until the parser is updated; pulling by name always works.
- **Servers**: an address without a port uses Ollama's default port 11434 (`192.168.1.20` → `http://192.168.1.20:11434`). The `OLLAMA_HOST` environment variable sets the default server.

| Path | Content |
| --- | --- |
| `Sources/OllamaKit` | API client, registry update checks, ollama.com parser (unit tested) |
| `Sources/OllamaGUI` | SwiftUI app |
| `Resources` | `Info.plist`, icon, English and French strings |
| `scripts` | build, test, icon and localization scripts |

## Privacy

No analytics, no account. The app only talks to the Ollama servers you configure, plus `ollama.com` when you open Discover and `registry.ollama.ai` when you check for updates.

## Français

**Ollama GUI** est une app macOS native pour gérer vos modèles Ollama : liste des modèles installés (taille, paramètres, quantification, capacités), détails complets, **recherche de mises à jour** sur le registre Ollama, téléchargement avec progression, bibliothèque ollama.com (recherche, tags, téléchargement en un clic), modèles en mémoire (chargement, déchargement, compte à rebours), duplication, renommage, **personnalisation** (prompt système et paramètres), suppression, et un **bac à sable** pour discuter avec un modèle et mesurer sa vitesse. Plusieurs serveurs, icône dans la barre des menus, interface en français et en anglais.

Installation : téléchargez le zip de la [dernière version](https://github.com/Hugo291/ollama-gui/releases/latest), dézippez, glissez l'app dans Applications, puis clic droit → **Ouvrir** au premier lancement (app non notarisée).

## License

[MIT](LICENSE). Ollama GUI is an independent project, not affiliated with Ollama.
