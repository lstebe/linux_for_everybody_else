# linux_for_everybody (`lfe`)

`lfe` nimmt eine natürliche Spracheingabe und schlägt einen Linux-Befehl vor.
Anschließend kannst du den Befehl im Terminal direkt bearbeiten und mit Enter ausführen.
Einfach nur `Enter` führt den vorgeschlagenen Befehl direkt aus (kein Kopieren nötig).

## Unterstützte Provider

- `ollama` (lokal, Default)
- `openai`
- `claude` (Anthropic)

## Schnellstart

```bash
cd /home/ls87742/code/linux_for_everybody
./lfe "gebe mir einen befehl um alle dateien in diesem ordner zu löschen, die vor heute erstellt wurden"
```

## Optionen

```bash
./lfe "..." --provider ollama
./lfe "..." --provider openai --model gpt-4o-mini
./lfe "..." --provider claude --model claude-3-5-sonnet-latest
./lfe "..." --print-only
```

## Persistente Konfiguration

Konfig-Datei:

- `~/.config/lfe/config.json` (oder `$XDG_CONFIG_HOME/lfe/config.json`)
- Optionaler Override: `LFE_CONFIG=/pfad/zu/config.json`

Wichtige Befehle:

```bash
lfe config path
lfe config show
lfe config set provider openai
lfe config set openai.base_url https://api.openai.com/v1
lfe config set openai.model gpt-4o-mini
lfe config set openai.token sk-...
lfe config set claude.token sk-ant-...
lfe config unset openai.token
```

Hinweis:

- `lfe config show` maskiert Tokens immer teilweise (`****`), nie im Klartext.
- Prioritaet bei Werten: CLI-flags > Umgebungsvariablen > Konfig-Datei > Defaults.
- Der System-Prompt enthaelt Laufzeit-Kontext: Distribution, `cwd`, Home-Pfad und Tree (Tiefe 2) von `cwd`.
- Wenn der vorgeschlagene Befehl flags nutzt, zeigt `lfe` strukturierte Erklaerungen pro flag an.
- Anfragen mit `-`-Teilen im Satz (z. B. `was macht das -f in tail`) werden als normaler Prompt behandelt.
- Wenn der Vorschlag ein reines `cd ...` ist, startet `lfe` eine Subshell im Zielordner.
- Ausgefuehrte `lfe`-Befehle werden in `HISTFILE` gespeichert (bash/zsh best effort); in einer laufenden bash-Sitzung ggf. `history -n` ausfuehren.

## Umgebungsvariablen

- `LFE_PROVIDER` (`ollama|openai|claude`)
- `OLLAMA_BASE_URL` (Default: `http://localhost:11434`)
- `OLLAMA_MODEL` (Default: `llama3.2`)
- `OPENAI_BASE_URL` (Default: `https://api.openai.com/v1`)
- `OPENAI_API_KEY`
- `OPENAI_MODEL` (Default: `gpt-4o-mini`)
- `ANTHROPIC_BASE_URL` oder `CLAUDE_BASE_URL` (Default: `https://api.anthropic.com/v1`)
- `ANTHROPIC_API_KEY`
- `CLAUDE_MODEL` oder `ANTHROPIC_MODEL` (Default: `claude-3-5-sonnet-latest`)

## Installation als globaler Befehl (optional)

```bash
sudo ln -s /home/<user>/code/linux_for_everybody/lfe /usr/local/bin/lfe
```

Danach kannst du überall `lfe "..."` ausführen.
