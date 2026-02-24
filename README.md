# linux_for_everybody (`lfe`)

`lfe` nimmt eine natürliche Spracheingabe und schlägt einen Linux-Befehl vor.
Anschließend kannst du den Befehl im Terminal direkt bearbeiten und mit Enter ausführen.
Einfach nur `Enter` führt den vorgeschlagenen Befehl direkt aus (kein Kopieren nötig).

## Unterstützte Provider

- `ollama` (Default: `https://ollama.com/api`)
- `openai`
- `claude` (Anthropic)

Hinweis: `README` und `lfe --help` werden inhaltlich synchron gehalten.

## Schnellstart

```bash
cd /pfad/zu/linux_for_everybody_else
./lfe "gebe mir einen befehl um alle dateien in diesem ordner zu löschen, die vor heute erstellt wurden"
```

## Python-Shebang Voraussetzung

`lfe` nutzt:

```bash
#!/usr/bin/env python3
```

Falls `python3` auf dem Zielsystem nicht im `PATH` gefunden wird:

```bash
command -v python3
```

Wenn nichts gefunden wird, nur dann einen Symlink setzen, falls `python` bereits auf Python 3 zeigt:

```bash
python --version
sudo ln -s "$(command -v python)" /usr/local/bin/python3
```

Prüfen:

```bash
command -v python3
python3 --version
```

Wenn `python` nicht vorhanden ist oder keine Python-3-Version ist, installiere `python3` ueber den Paketmanager statt zu symlinken.

## Optionen

```bash
./lfe "..." --provider ollama
./lfe "..." --provider openai --model gpt-4o-mini
./lfe "..." --provider claude --model claude-3-5-sonnet-latest
./lfe "..." --print-only
```

## Antwortsprache (DE/EN)

`lfe` erwartet vom Modell eine Sprach-Klassifizierung im JSON:

- `language=DE` nur bei deutscher Anfrage
- sonst immer `language=EN` (auch fuer alle anderen Sprachen)

Zusatz: Die fest verdrahteten Laufzeit-Ausgaben von `lfe` (z. B. Warnungen, Prompts, Fehlertexte)
nutzen dieselbe Sprache (`DE` oder `EN`).

## Persistente Konfiguration

Konfig-Datei:

- `~/.config/lfe/config.json` (oder `$XDG_CONFIG_HOME/lfe/config.json`)
- Optionaler Override: `LFE_CONFIG=/pfad/zu/config.json`

Wichtige Befehle:

```bash
lfe config path
lfe config show
lfe config set provider ollama
lfe config set ollama.base_url https://ollama.com/api
lfe config set provider openai
lfe config set openai.base_url https://api.openai.com/v1
lfe config set openai.model gpt-4o-mini
lfe config unset ollama.base_url
```

Hinweis:

- Prioritaet bei Werten: CLI-flags > Umgebungsvariablen > Konfig-Datei > Defaults.
- Tokens werden nicht in `config.json` gespeichert.
- Der System-Prompt enthaelt Laufzeit-Kontext: Distribution, `cwd`, Home-Pfad und Tree (Tiefe 2) von `cwd`.
- Wenn der vorgeschlagene Befehl flags nutzt, zeigt `lfe` strukturierte Erklaerungen pro flag an.
- Anfragen mit `-`-Teilen im Satz (z. B. `was macht das -f in tail`) werden als normaler Prompt behandelt.
- Wenn der Vorschlag ein reines `cd ...` ist, startet `lfe` eine Subshell im Zielordner.
- Ausgefuehrte `lfe`-Befehle werden in `HISTFILE` gespeichert (bash/zsh best effort); in einer laufenden bash-Sitzung ggf. `history -n` ausfuehren.

## Umgebungsvariablen

- `LFE_PROVIDER` (`ollama|openai|claude`)
- `OLLAMA_BASE_URL` (Default: `https://ollama.com/api`)
- `LFEE_TOKEN_OLLAMA` (oder `OLLAMA_API_KEY`)
- `OLLAMA_MODEL` (Default: `llama3.2`)
- `OPENAI_BASE_URL` (Default: `https://api.openai.com/v1`)
- `LFEE_TOKEN_OPENAI` (oder `OPENAI_API_KEY`)
- `OPENAI_MODEL` (Default: `gpt-4o-mini`)
- `ANTHROPIC_BASE_URL` oder `CLAUDE_BASE_URL` (Default: `https://api.anthropic.com/v1`)
- `LFEE_TOKEN_CLAUDE` (oder `ANTHROPIC_API_KEY` oder `CLAUDE_API_KEY`)
- `CLAUDE_MODEL` oder `ANTHROPIC_MODEL` (Default: `claude-3-5-sonnet-latest`)

## Persistente Tokens (`LFEE_TOKEN_<PROVIDER>`)

Beispiele:

```bash
export LFEE_TOKEN_OLLAMA="ollama_..."
export LFEE_TOKEN_OPENAI="sk-..."
export LFEE_TOKEN_CLAUDE="sk-ant-..."
```

Persistent fuer Bash (`~/.bashrc`):

```bash
echo 'export LFEE_TOKEN_OLLAMA="ollama_..."' >> ~/.bashrc
echo 'export LFEE_TOKEN_OPENAI="sk-..."' >> ~/.bashrc
echo 'export LFEE_TOKEN_CLAUDE="sk-ant-..."' >> ~/.bashrc
source ~/.bashrc
```

Persistent fuer Zsh (`~/.zshrc`):

```bash
echo 'export LFEE_TOKEN_OLLAMA="ollama_..."' >> ~/.zshrc
echo 'export LFEE_TOKEN_OPENAI="sk-..."' >> ~/.zshrc
echo 'export LFEE_TOKEN_CLAUDE="sk-ant-..."' >> ~/.zshrc
source ~/.zshrc
```

### Ollama Cloud (ohne lokalen Ollama-Daemon)

```bash
export OLLAMA_BASE_URL="https://ollama.com/api"
export LFEE_TOKEN_OLLAMA="ollama_..."
./lfe "zeige alle python dateien im aktuellen ordner" --provider ollama
```

## Installation als globaler Befehl (optional)

```bash
sudo ln -s /pfad/zu/linux_for_everybody_else/lfe /usr/local/bin/lfe
```

Danach kannst du überall `lfe "..."` ausführen.

## Standalone-Binary bauen

Auf einem System mit Internetzugriff kannst du eine echte Standalone-Binary bauen:

```bash
./scripts/build_standalone.sh
```

Ergebnis:

- `dist/lfe`

Hinweis:

- Die Binary ist plattformgebunden (Linux-Build fuer Linux, macOS-Build fuer macOS).
