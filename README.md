

# linux_for_everybody_else (`lfe`)

![Demo GIF](./lfe%20tryout.gif)

`lfe` takes a natural language input and suggests a Linux command.
You can then edit the command directly in the terminal and execute it by pressing Enter.
Pressing **Enter** immediately executes the suggested command (no copy & paste required).

## Supported Providers

* `ollama` (default: `https://ollama.com/api`)
* `openai`
* `claude` (Anthropic)

Note: `README` and `lfe --help` are kept content-synchronized.

## Quick Start

```bash
cd /path/to/linux_for_everybody_else
./lfe "give me a command to delete all files in this directory that were created before today"
```

## Python Shebang Requirement

`lfe` uses:

```bash
#!/usr/bin/env python3
```

If `python3` is not found in `PATH` on the target system:

```bash
command -v python3
```

If nothing is found, only then create a symlink **if** `python` already points to Python 3:

```bash
python --version
sudo ln -s "$(command -v python)" /usr/local/bin/python3
```

Verify:

```bash
command -v python3
python3 --version
```

If `python` is not present or is not a Python 3 version, install `python3` via the package manager instead of symlinking.

## Options

```bash
./lfe "..." --provider ollama
./lfe "..." --provider openai --model gpt-4o-mini
./lfe "..." --provider claude --model claude-3-5-sonnet-latest
./lfe "..." --print-only
```

## Response Language (DE / EN)

`lfe` expects a language classification from the model in JSON:

* `language=DE` only for German requests
* otherwise always `language=EN` (including all other languages)

Additionally, the hard-coded runtime output of `lfe` (e.g. warnings, prompts, error messages) uses the same language (`DE` or `EN`).

## Persistent Configuration

Config file:

* `~/.config/lfe/config.json` (or `$XDG_CONFIG_HOME/lfe/config.json`)
* Optional override: `LFE_CONFIG=/path/to/config.json`

Important commands:

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

Notes:

* Value precedence: CLI flags > environment variables > config file > defaults.
* Tokens are not stored in `config.json`.
* The system prompt includes runtime context: distribution, `cwd`, home path, and a directory tree (depth 2) of `cwd`.
* If the suggested command uses flags, `lfe` shows structured explanations per flag.
* Requests containing `-` segments in the sentence (e.g. `what does -f do in tail`) are treated as a normal prompt.
* If the suggestion is a pure `cd ...`, `lfe` starts a subshell in the target directory.
* Executed `lfe` commands are written to `HISTFILE` (bash/zsh best effort); in an active bash session you may need to run `history -n`.

## Environment Variables

* `LFE_PROVIDER` (`ollama|openai|claude`)
* `OLLAMA_BASE_URL` (default: `https://ollama.com/api`)
* `LFEE_TOKEN_OLLAMA` (or `OLLAMA_API_KEY`)
* `OLLAMA_MODEL` (default: `llama3.2`)
* `OPENAI_BASE_URL` (default: `https://api.openai.com/v1`)
* `LFEE_TOKEN_OPENAI` (or `OPENAI_API_KEY`)
* `OPENAI_MODEL` (default: `gpt-4o-mini`)
* `ANTHROPIC_BASE_URL` or `CLAUDE_BASE_URL` (default: `https://api.anthropic.com/v1`)
* `LFEE_TOKEN_CLAUDE` (or `ANTHROPIC_API_KEY` or `CLAUDE_API_KEY`)
* `CLAUDE_MODEL` or `ANTHROPIC_MODEL` (default: `claude-3-5-sonnet-latest`)

## Persistent Tokens (`LFEE_TOKEN_<PROVIDER>`)

Examples:

```bash
export LFEE_TOKEN_OLLAMA="ollama_..."
export LFEE_TOKEN_OPENAI="sk-..."
export LFEE_TOKEN_CLAUDE="sk-ant-..."
```

Persistent for Bash (`~/.bashrc`):

```bash
echo 'export LFEE_TOKEN_OLLAMA="ollama_..."' >> ~/.bashrc
echo 'export LFEE_TOKEN_OPENAI="sk-..."' >> ~/.bashrc
echo 'export LFEE_TOKEN_CLAUDE="sk-ant-..."' >> ~/.bashrc
source ~/.bashrc
```

Persistent for Zsh (`~/.zshrc`):

```bash
echo 'export LFEE_TOKEN_OLLAMA="ollama_..."' >> ~/.zshrc
echo 'export LFEE_TOKEN_OPENAI="sk-..."' >> ~/.zshrc
echo 'export LFEE_TOKEN_CLAUDE="sk-ant-..."' >> ~/.zshrc
source ~/.zshrc
```

### Ollama Cloud (without a local Ollama daemon)

```bash
export OLLAMA_BASE_URL="https://ollama.com/api"
export LFEE_TOKEN_OLLAMA="ollama_..."
./lfe "show all python files in the current directory" --provider ollama
```

## Install as a Global Command (optional)

```bash
sudo ln -s /path/to/linux_for_everybody_else/lfe /usr/local/bin/lfe
```

After that, you can run `lfe "..."` from anywhere.

## Build Standalone Binary

On a system with internet access you can build a true standalone binary:

```bash
./scripts/build_standalone.sh
```

Result:

* `dist/lfe`

Note:

* The binary is platform-specific (Linux build for Linux, macOS build for macOS).
