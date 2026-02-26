#!/usr/bin/env python3
"""lfe: natural language to shell command helper."""

from __future__ import annotations

import argparse
import json
import os
import platform
import readline
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Tuple


def ensure_project_venv() -> None:
    script_path = Path(__file__).resolve()
    if os.name == "nt":
        target = script_path.parent / ".venv" / "Scripts" / "python.exe"
    else:
        target = script_path.parent / ".venv" / "bin" / "python"

    if not target.exists():
        return

    try:
        current = Path(sys.executable).resolve()
        expected = target.resolve()
    except OSError:
        return

    if current == expected:
        return

    os.execv(str(expected), [str(expected), str(script_path), *sys.argv[1:]])


ensure_project_venv()


SYSTEM_PROMPT = """You are lfe, a Linux shell assistant.
Respond only with a valid JSON object and no Markdown.
Use exactly this schema:
{
  "language": "DE or EN",
  "explanation": "short explanation in the request language",
  "command": "a single Linux command that works directly in the current directory",
  "flag_explanations": [
    {"flag": "-x", "meaning": "meaning of -x"},
    {"flag": "--example", "meaning": "meaning of --example"}
  ],
  "warnings": ["optional warning 1", "optional warning 2"]
}
Rules:
- Classify the language and set "language":
  - "DE" only when the user request is German.
  - otherwise always "EN" (including all other languages).
- Output exactly ONE command in "command".
- When command contains paths with whitespace, make sure that fitting quotation maks are used.
- If the command uses flags, fill "flag_explanations" with exactly those flags.
- If no flags are used, output "flag_explanations": [].
- Use safe defaults when possible (for example show first instead of deleting directly), and explain that in explanation.
- If the command may delete files, include a concrete dry-run hint in explanation when possible.
- If "language" = "DE", write explanation/flag_explanations/warnings in German.
- If "language" = "EN", write explanation/flag_explanations/warnings in English.
- Use relative paths (.) or the provided cwd.
- No backticks, no extra text, JSON only.
- When you are asked for creating multiline file content, make correct use of heredoc (EOF) 
"""


PROVIDERS = ("ollama", "openai", "claude")

DEFAULTS: Dict[str, Dict[str, str]] = {
    "ollama": {
        "base_url": "https://ollama.com/api",
        "model": "llama3.2",
    },
    "openai": {
        "base_url": "https://api.openai.com/v1",
        "model": "gpt-4o-mini",
    },
    "claude": {
        "base_url": "https://api.anthropic.com/v1",
        "model": "claude-3-5-sonnet-latest",
    },
}

ENV_KEYS: Dict[str, Dict[str, Tuple[str, ...]]] = {
    "ollama": {
        "base_url": ("OLLAMA_BASE_URL",),
        "model": ("OLLAMA_MODEL",),
        "api_key": ("LFEE_TOKEN_OLLAMA", "OLLAMA_API_KEY"),
    },
    "openai": {
        "base_url": ("OPENAI_BASE_URL",),
        "model": ("OPENAI_MODEL",),
        "api_key": ("LFEE_TOKEN_OPENAI", "OPENAI_API_KEY"),
    },
    "claude": {
        "base_url": ("ANTHROPIC_BASE_URL", "CLAUDE_BASE_URL"),
        "model": ("CLAUDE_MODEL", "ANTHROPIC_MODEL"),
        "api_key": ("LFEE_TOKEN_CLAUDE", "ANTHROPIC_API_KEY", "CLAUDE_API_KEY"),
    },
}

UI_TEXTS: Dict[str, Dict[str, str]] = {
    "de": {
        "missing_flag_explanation": "Keine Erklaerung vom Modell geliefert.",
        "empty_request": "Leere Anfrage.",
        "llm_error": "LLM-Fehler: {error}",
        "invalid_command": "Keine gueltige command-Antwort vom Modell: {parsed}",
        "flag_header": "\nFlag-Erklaerungen:",
        "warnings_header": "\nWarnungen:",
        "enter_to_run": "\nTippe Enter, um den Befehl auszufuehren (du kannst ihn vorher bearbeiten).",
        "ctrl_c": "Ctrl+C zum Abbrechen.",
        "multiline_edit_hint": (
            "Mehrzeiliger Befehl erkannt. Enter fuehrt ihn unveraendert aus; "
            "du kannst optional einen einzeiligen Ersatz eingeben."
        ),
        "suggestion": "\nVorschlag:",
        "cancelled": "\nAbgebrochen.",
        "cd_error": "\ncd-Fehler: {error}",
        "changed_dir": "\nWechsle nach: {cwd}",
        "start_subshell": "Starte Subshell. Mit 'exit' kommst du zurueck.",
        "cd_parent_shell": "\nHinweis: 'cd' kann das Eltern-Shell nicht direkt aendern. Ziel waere: {cwd}",
        "stdout_stderr": "\nstdout/stderr:",
        "http_error": "HTTP {code} von {url}: {body}",
        "network_error": "Netzwerkfehler bei {url}: {error}",
        "ollama_missing_key": "Ollama Cloud API-Token fehlt (setze LFEE_TOKEN_OLLAMA oder OLLAMA_API_KEY).",
        "openai_missing_key": "OpenAI API-Token fehlt (setze LFEE_TOKEN_OPENAI oder OPENAI_API_KEY).",
        "claude_missing_key": "Claude API-Token fehlt (setze LFEE_TOKEN_CLAUDE oder ANTHROPIC_API_KEY).",
        "unexpected_openai": "Unerwartete OpenAI-Antwort: {data}",
        "unexpected_claude": "Unerwartete Claude-Antwort: {data}",
        "provider_not_supported": "Provider nicht unterstuetzt: {provider}",
    },
    "en": {
        "missing_flag_explanation": "No explanation was provided by the model.",
        "empty_request": "Empty request.",
        "llm_error": "LLM error: {error}",
        "invalid_command": "No valid command returned by the model: {parsed}",
        "flag_header": "\nFlag explanations:",
        "warnings_header": "\nWarnings:",
        "enter_to_run": "\nPress Enter to run the command (you can edit it first).",
        "ctrl_c": "Press Ctrl+C to cancel.",
        "multiline_edit_hint": (
            "Multiline command detected. Press Enter to run it unchanged; "
            "you may optionally enter a one-line replacement."
        ),
        "suggestion": "\nSuggestion:",
        "cancelled": "\nCancelled.",
        "cd_error": "\ncd error: {error}",
        "changed_dir": "\nChanging to: {cwd}",
        "start_subshell": "Starting a subshell. Use 'exit' to return.",
        "cd_parent_shell": "\nNote: 'cd' cannot directly change the parent shell. Target would be: {cwd}",
        "stdout_stderr": "\nstdout/stderr:",
        "http_error": "HTTP {code} from {url}: {body}",
        "network_error": "Network error at {url}: {error}",
        "ollama_missing_key": "Ollama Cloud API token is missing (set LFEE_TOKEN_OLLAMA or OLLAMA_API_KEY).",
        "openai_missing_key": "OpenAI API token is missing (set LFEE_TOKEN_OPENAI or OPENAI_API_KEY).",
        "claude_missing_key": "Claude API token is missing (set LFEE_TOKEN_CLAUDE or ANTHROPIC_API_KEY).",
        "unexpected_openai": "Unexpected OpenAI response: {data}",
        "unexpected_claude": "Unexpected Claude response: {data}",
        "provider_not_supported": "Provider not supported: {provider}",
    },
}


def ui_lang_or_default(ui_lang: str) -> str:
    return "de" if ui_lang == "de" else "en"


def t(ui_lang: str, key: str, **kwargs: Any) -> str:
    lang = ui_lang_or_default(ui_lang)
    template = UI_TEXTS[lang][key]
    return template.format(**kwargs)


def classify_request_language(request: str) -> str:
    text = request.strip().lower()
    if not text:
        return "en"
    if any(ch in text for ch in "äöüß"):
        return "de"
    tokens = re.findall(r"[a-zA-Zäöüß]+", text)
    german_markers = {
        "bitte",
        "zeige",
        "loesche",
        "lösche",
        "datei",
        "dateien",
        "ordner",
        "befehl",
        "welche",
        "wie",
        "und",
        "nicht",
        "fuer",
        "für",
        "mit",
        "ohne",
    }
    if any(tok in german_markers for tok in tokens):
        return "de"
    return "en"


def normalize_model_language(raw: Any) -> str | None:
    value = str(raw or "").strip().lower()
    if value in ("de", "deu", "ger", "german", "deutsch"):
        return "de"
    if value in ("en", "eng", "english"):
        return "en"
    return None


def config_path() -> Path:
    explicit = os.getenv("LFE_CONFIG")
    if explicit:
        return Path(explicit).expanduser()
    base_dir = os.getenv("XDG_CONFIG_HOME", "")
    if base_dir:
        return Path(base_dir).expanduser() / "lfe" / "config.json"
    return Path.home() / ".config" / "lfe" / "config.json"


def default_config() -> Dict[str, Any]:
    return {
        "provider": "ollama",
        "providers": {
            name: {
                "base_url": DEFAULTS[name]["base_url"],
                "model": DEFAULTS[name]["model"],
            }
            for name in PROVIDERS
        },
    }


def normalize_config(data: Any) -> Dict[str, Any]:
    conf = default_config()
    if not isinstance(data, dict):
        return conf

    provider = data.get("provider")
    if provider in PROVIDERS:
        conf["provider"] = provider

    providers = data.get("providers")
    if isinstance(providers, dict):
        for name in PROVIDERS:
            section = providers.get(name)
            if not isinstance(section, dict):
                continue
            for key in ("base_url", "model"):
                val = section.get(key)
                if isinstance(val, str):
                    conf["providers"][name][key] = val
    return conf


def load_config() -> Dict[str, Any]:
    path = config_path()
    if not path.exists():
        return default_config()
    try:
        raw = path.read_text(encoding="utf-8")
        return normalize_config(json.loads(raw))
    except Exception:
        return default_config()


def write_private_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
    finally:
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass


def save_config(conf: Dict[str, Any]) -> None:
    normalized = normalize_config(conf)
    serialized = json.dumps(normalized, ensure_ascii=True, indent=2) + "\n"
    write_private_text(config_path(), serialized)


def parse_args(argv: List[str]) -> argparse.Namespace:
    if argv and argv[0] == "config":
        parser = argparse.ArgumentParser(prog="lfe config", description="lfe configuration")
        sub = parser.add_subparsers(dest="config_cmd", required=True)
        sub.add_parser("path", help="Show config file path")
        sub.add_parser("show", help="Show current configuration")
        set_parser = sub.add_parser("set", help="Set a value")
        set_parser.add_argument(
            "key",
            help="e.g. provider, ollama.base_url, openai.model, claude.base_url",
        )
        set_parser.add_argument("value", help="New value")
        unset_parser = sub.add_parser("unset", help="Reset value to default")
        unset_parser.add_argument("key", help="e.g. ollama.model, openai.base_url, claude.model")
        parsed = parser.parse_args(argv[1:])
        parsed.mode = "config"
        return parsed

    epilog = (
        "Environment:\n"
        "  LFE_PROVIDER=ollama|openai|claude\n"
        "  OLLAMA_BASE_URL (Default: https://ollama.com/api)\n"
        "  LFEE_TOKEN_OLLAMA (or OLLAMA_API_KEY)\n"
        "  LFEE_TOKEN_OPENAI (or OPENAI_API_KEY)\n"
        "  LFEE_TOKEN_CLAUDE (or ANTHROPIC_API_KEY/CLAUDE_API_KEY)\n"
        "  OLLAMA_MODEL\n\n"
        "Python shebang note:\n"
        "  lfe uses #!/usr/bin/env python3\n"
        "  If python3 is missing: first check python --version (must be Python 3), then\n"
        "  sudo ln -s \"$(command -v python)\" /usr/local/bin/python3\n\n"
        "Response language:\n"
        "  Model returns language=DE|EN.\n"
        "  DE only for German requests, otherwise EN.\n\n"
        "Standalone binary:\n"
        "  ./scripts/build_standalone.sh\n\n"
        "Ollama.com example:\n"
        "  OLLAMA_BASE_URL=https://ollama.com/api \\\n"
        "  LFEE_TOKEN_OLLAMA=ollama_... \\\n"
        "  lfe --provider ollama \"show all python files\""
    )
    parser = argparse.ArgumentParser(
        prog="lfe",
        description="Natural language to Linux command via LLM.",
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("prompt", nargs="*", help="Natural language input for the shell command")
    parser.add_argument(
        "--provider",
        choices=PROVIDERS,
        default=None,
        help="LLM provider (overrides configuration for this call)",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Model name (overrides configuration for this call)",
    )
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="Only print command, do not execute interactively",
    )
    if argv in (["-h"], ["--help"]):
        parser.print_help()
        raise SystemExit(0)

    provider: str | None = None
    model: str | None = None
    print_only = False

    idx = 0
    while idx < len(argv):
        tok = argv[idx]
        if tok == "--":
            idx += 1
            break
        if tok == "--print-only":
            print_only = True
            idx += 1
            continue
        if tok == "--provider":
            if idx + 1 >= len(argv):
                parser.error("--provider expects a value.")
            provider = argv[idx + 1]
            idx += 2
            continue
        if tok.startswith("--provider="):
            provider = tok.split("=", 1)[1]
            idx += 1
            continue
        if tok == "--model":
            if idx + 1 >= len(argv):
                parser.error("--model expects a value.")
            model = argv[idx + 1]
            idx += 2
            continue
        if tok.startswith("--model="):
            model = tok.split("=", 1)[1]
            idx += 1
            continue
        break

    if provider is not None and provider not in PROVIDERS:
        parser.error(
            f"argument --provider: invalid choice: '{provider}' "
            f"(choose from {', '.join(PROVIDERS)})"
        )

    prompt = argv[idx:]
    if not prompt:
        parser.error("Natural language input for the shell command is missing.")

    return argparse.Namespace(
        mode="run",
        prompt=prompt,
        provider=provider,
        model=model,
        print_only=print_only,
    )


def default_model(provider: str) -> str:
    return DEFAULTS[provider]["model"]


def read_os_release() -> Dict[str, str]:
    path = Path("/etc/os-release")
    if not path.exists():
        return {}
    data: Dict[str, str] = {}
    try:
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip()
            if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")):
                val = val[1:-1]
            data[key] = val
    except OSError:
        return {}
    return data


def detect_distribution() -> str:
    os_rel = read_os_release()
    if os_rel.get("PRETTY_NAME"):
        return os_rel["PRETTY_NAME"]
    name = os_rel.get("NAME", "").strip()
    version = os_rel.get("VERSION_ID", "").strip()
    if name and version:
        return f"{name} {version}"
    if name:
        return name
    return platform.platform()


def render_tree(root: Path, max_depth: int = 2, max_entries: int = 200) -> str:
    lines = ["."] if root.exists() else [f"<not found: {root}>"]
    if not root.exists() or not root.is_dir():
        return "\n".join(lines)

    entries = 0
    truncated = False

    def walk(path: Path, depth: int, indent: str) -> None:
        nonlocal entries, truncated
        if truncated:
            return
        try:
            children = sorted(path.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        except OSError as err:
            lines.append(f"{indent}- <access denied: {err}>")
            return

        for child in children:
            if entries >= max_entries:
                truncated = True
                return

            name = child.name.replace("\n", "\\n")
            is_dir = False
            try:
                is_dir = child.is_dir()
            except OSError:
                is_dir = False
            is_symlink = child.is_symlink()
            suffix = "/" if is_dir else ""
            if is_symlink:
                suffix += "@"

            lines.append(f"{indent}- {name}{suffix}")
            entries += 1

            if is_dir and not is_symlink and depth < max_depth:
                walk(child, depth + 1, indent + "  ")
                if truncated:
                    return

    walk(root, 0, "")
    if truncated:
        lines.append(f"... (truncated after {max_entries} entries)")
    return "\n".join(lines)


def build_system_prompt(cwd: str) -> str:
    distro = detect_distribution()
    home_path = str(Path.home())
    cwd_tree = render_tree(Path(cwd), max_depth=2, max_entries=200)
    context_block = (
        "\n\nRuntime context (for better local shell commands):\n"
        f"- Distribution: {distro}\n"
        f"- Local working directory (cwd): {cwd}\n"
        f"- Home path: {home_path}\n"
        "- Tree (depth 2) of the local working directory:\n"
        f"{cwd_tree}\n"
    )
    return SYSTEM_PROMPT + context_block


def http_post_json(
    url: str, payload: Dict[str, Any], headers: Dict[str, str], ui_lang: str
) -> Dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read().decode("utf-8")
            return json.loads(data)
    except urllib.error.HTTPError as err:
        error_body = err.read().decode("utf-8", errors="replace")
        raise RuntimeError(t(ui_lang, "http_error", code=err.code, url=url, body=error_body)) from err
    except urllib.error.URLError as err:
        raise RuntimeError(t(ui_lang, "network_error", url=url, error=err)) from err


def looks_like_ollama_cloud(base_url: str) -> bool:
    candidate = base_url.strip()
    if not candidate:
        return False

    if "://" not in candidate:
        candidate = f"https://{candidate}"
    parsed = urllib.parse.urlparse(candidate)
    host = (parsed.netloc or parsed.path).split("/")[0].lower()
    return host == "ollama.com" or host.endswith(".ollama.com")


def ollama_chat_endpoint(base_url: str) -> str:
    clean = base_url.strip().rstrip("/")
    if clean.endswith("/api"):
        return f"{clean}/chat"
    return f"{clean}/api/chat"


def call_ollama(
    base_url: str, api_key: str, model: str, system_prompt: str, user_prompt: str, ui_lang: str
) -> str:
    if looks_like_ollama_cloud(base_url) and not api_key:
        raise RuntimeError(t(ui_lang, "ollama_missing_key"))

    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "options": {"temperature": 0.1},
    }
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    data = http_post_json(
        ollama_chat_endpoint(base_url),
        payload,
        headers=headers,
        ui_lang=ui_lang,
    )
    return data.get("message", {}).get("content", "")


def call_openai(
    base_url: str, api_key: str, model: str, system_prompt: str, user_prompt: str, ui_lang: str
) -> str:
    if not api_key:
        raise RuntimeError(t(ui_lang, "openai_missing_key"))
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.1,
    }
    data = http_post_json(
        f"{base_url.rstrip('/')}/chat/completions",
        payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        ui_lang=ui_lang,
    )
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as err:
        raise RuntimeError(t(ui_lang, "unexpected_openai", data=data)) from err


def call_claude(
    base_url: str, api_key: str, model: str, system_prompt: str, user_prompt: str, ui_lang: str
) -> str:
    if not api_key:
        raise RuntimeError(t(ui_lang, "claude_missing_key"))
    payload = {
        "model": model,
        "system": system_prompt,
        "max_tokens": 800,
        "temperature": 0.1,
        "messages": [{"role": "user", "content": user_prompt}],
    }
    data = http_post_json(
        f"{base_url.rstrip('/')}/messages",
        payload,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
        ui_lang=ui_lang,
    )
    try:
        blocks = data["content"]
        return "\n".join(block["text"] for block in blocks if block.get("type") == "text")
    except (KeyError, TypeError) as err:
        raise RuntimeError(t(ui_lang, "unexpected_claude", data=data)) from err


def extract_json(raw_text: str) -> Dict[str, Any]:
    text = raw_text.strip()
    if text.startswith("```"):
        text = text.strip("`")
        first_nl = text.find("\n")
        if first_nl != -1:
            text = text[first_nl + 1 :]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1 and end > start:
            return json.loads(text[start : end + 1])
        raise


def editable_input(prompt: str, prefill: str) -> str:
    # read -e/-i ist rein einzeilig. Bei Heredoc/Multiline-Kommandos darf
    # der Prefill nicht abgeschnitten werden, sonst geht z. B. der Body verloren.
    if "\n" in prefill or "\r" in prefill:
        return input(prompt)

    # GNU Readline via bash zeigt den Prefill in vielen Terminals stabiler an
    # als Python input()+readline allein.
    bash_path = shutil.which("bash")
    if bash_path and sys.stdin.isatty() and sys.stdout.isatty():
        with tempfile.NamedTemporaryFile(mode="w", delete=False, encoding="utf-8") as tmp:
            tmp_path = tmp.name
        try:
            env = os.environ.copy()
            env["LFE_PROMPT"] = prompt
            env["LFE_PREFILL"] = prefill
            env["LFE_TMPFILE"] = tmp_path
            proc = subprocess.run(
                [
                    bash_path,
                    "-c",
                    'read -e -i "$LFE_PREFILL" -p "$LFE_PROMPT" LFE_OUT; '
                    'printf "%s" "$LFE_OUT" > "$LFE_TMPFILE"',
                ],
                env=env,
                check=False,
            )
            if proc.returncode == 130:
                raise KeyboardInterrupt
            try:
                return Path(tmp_path).read_text(encoding="utf-8")
            except OSError:
                return ""
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    # Fallback (z. B. wenn bash nicht verfuegbar ist).
    readline.set_startup_hook(lambda: readline.insert_text(prefill))
    try:
        return input(prompt)
    finally:
        readline.set_startup_hook(None)


def env_value(provider: str, key: str) -> str:
    for env_name in ENV_KEYS[provider][key]:
        val = os.getenv(env_name, "")
        if val:
            return val
    return ""


def resolve_runtime_config(
    args: argparse.Namespace, conf: Dict[str, Any]
) -> Tuple[str, str, str, str]:
    provider = (
        args.provider
        or os.getenv("LFE_PROVIDER", "").strip()
        or conf.get("provider", "")
        or "ollama"
    )
    if provider not in PROVIDERS:
        provider = "ollama"

    provider_conf = conf.get("providers", {}).get(provider, {})
    model = args.model or env_value(provider, "model") or provider_conf.get("model", "")
    if not model:
        model = default_model(provider)
    base_url = env_value(provider, "base_url") or provider_conf.get("base_url", "")
    if not base_url:
        base_url = DEFAULTS[provider]["base_url"]
    api_key = env_value(provider, "api_key")
    return provider, model, base_url, api_key


def normalize_key(key: str) -> str:
    key = key.strip().lower()
    return key


def set_config_value(conf: Dict[str, Any], raw_key: str, value: str) -> None:
    key = normalize_key(raw_key)
    if key == "provider":
        if value not in PROVIDERS:
            raise ValueError(f"Invalid provider: {value}. Allowed: {', '.join(PROVIDERS)}")
        conf["provider"] = value
        return

    parts = key.split(".")
    if len(parts) != 2:
        raise ValueError(
            "Invalid key. Examples: provider, ollama.base_url, openai.model, claude.base_url"
        )
    provider, field = parts
    if provider not in PROVIDERS:
        raise ValueError(f"Unknown provider in key: {provider}")
    if field not in ("model", "base_url"):
        raise ValueError(f"Invalid field in key: {field}")
    conf["providers"][provider][field] = value


def unset_config_value(conf: Dict[str, Any], raw_key: str) -> None:
    key = normalize_key(raw_key)
    if key == "provider":
        conf["provider"] = "ollama"
        return

    parts = key.split(".")
    if len(parts) != 2:
        raise ValueError(
            "Invalid key. Examples: provider, ollama.base_url, openai.model, claude.base_url"
        )
    provider, field = parts
    if provider not in PROVIDERS:
        raise ValueError(f"Unknown provider in key: {provider}")
    if field not in ("model", "base_url"):
        raise ValueError(f"Invalid field in key: {field}")
    conf["providers"][provider][field] = DEFAULTS[provider][field]


def handle_config(args: argparse.Namespace, conf: Dict[str, Any]) -> int:
    if args.config_cmd == "path":
        print(config_path())
        return 0
    if args.config_cmd == "show":
        print(json.dumps(normalize_config(conf), ensure_ascii=True, indent=2))
        return 0
    if args.config_cmd == "set":
        try:
            set_config_value(conf, args.key, args.value)
            save_config(conf)
        except ValueError as err:
            print(err, file=sys.stderr)
            return 2
        print(f"Saved: {args.key}")
        return 0
    if args.config_cmd == "unset":
        try:
            unset_config_value(conf, args.key)
            save_config(conf)
        except ValueError as err:
            print(err, file=sys.stderr)
            return 2
        print(f"Reset: {args.key}")
        return 0
    return 2


def call_provider(
    provider: str,
    base_url: str,
    api_key: str,
    model: str,
    system_prompt: str,
    user_prompt: str,
    ui_lang: str,
) -> str:
    if provider == "ollama":
        return call_ollama(base_url, api_key, model, system_prompt, user_prompt, ui_lang)
    if provider == "openai":
        return call_openai(base_url, api_key, model, system_prompt, user_prompt, ui_lang)
    if provider == "claude":
        return call_claude(base_url, api_key, model, system_prompt, user_prompt, ui_lang)
    raise RuntimeError(t(ui_lang, "provider_not_supported", provider=provider))


def configure_stdio() -> None:
    # Verhindert UnicodeEncodeError bei alten/non-UTF8 Locales
    # (z. B. iso8859_15), indem nicht darstellbare Zeichen ersetzt werden.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except Exception:
            pass


def parse_plain_cd(command: str) -> str | None:
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    if not tokens:
        return None
    if tokens[0] != "cd":
        return None
    if len(tokens) == 1:
        return os.path.expanduser("~")
    if len(tokens) == 2:
        return os.path.expanduser(tokens[1])
    return None


def detect_history_file() -> Path:
    histfile = os.getenv("HISTFILE", "").strip()
    if histfile:
        return Path(histfile).expanduser()
    shell_name = Path(os.getenv("SHELL", "")).name
    if shell_name == "zsh":
        return Path.home() / ".zsh_history"
    return Path.home() / ".bash_history"


def zsh_uses_extended_history(path: Path) -> bool:
    if not path.exists():
        return False
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 8192), os.SEEK_SET)
            chunk = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return False
    for line in chunk.splitlines()[-20:]:
        if line.startswith(": ") and ";" in line:
            return True
    return False


def append_to_shell_history(command: str) -> None:
    cmd = command.strip()
    if not cmd:
        return

    path = detect_history_file()
    shell_name = Path(os.getenv("SHELL", "")).name
    if shell_name == "zsh" and zsh_uses_extended_history(path):
        line = f": {int(time.time())}:0;{cmd}\n"
    else:
        line = f"{cmd}\n"

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            with os.fdopen(fd, "a", encoding="utf-8", errors="replace") as handle:
                handle.write(line)
        finally:
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
    except OSError:
        # History ist best effort; Ausfuehrung des Befehls soll nicht blockieren.
        return


def extract_flags_from_command(command: str) -> List[str]:
    try:
        tokens = shlex.split(command)
    except ValueError:
        return []

    flags: List[str] = []
    seen: set[str] = set()

    for tok in tokens:
        if not tok or tok == "-" or tok == "--":
            continue
        if tok.startswith("--"):
            flag = tok.split("=", 1)[0]
            if flag not in seen:
                seen.add(flag)
                flags.append(flag)
            continue
        if not tok.startswith("-"):
            continue

        body = tok[1:]
        if not body or body[0].isdigit():
            continue

        # z. B. -n5 -> -n
        if len(body) >= 2 and body[0].isalpha() and body[1:].isdigit():
            flag = f"-{body[0]}"
            if flag not in seen:
                seen.add(flag)
                flags.append(flag)
            continue

        # z. B. -rf, -la -> einzelne Short-Flags
        if body.isalpha() and len(body) <= 3:
            for ch in body:
                flag = f"-{ch}"
                if flag not in seen:
                    seen.add(flag)
                    flags.append(flag)
            continue

        # z. B. -maxdepth oder -name
        flag = tok.split("=", 1)[0]
        if flag not in seen:
            seen.add(flag)
            flags.append(flag)

    return flags


def normalize_flag_explanations(raw: Any) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not isinstance(raw, list):
        return out
    for item in raw:
        if not isinstance(item, dict):
            continue
        flag = str(item.get("flag", "")).strip()
        meaning = str(
            item.get("meaning")
            or item.get("description")
            or item.get("explanation")
            or ""
        ).strip()
        if not flag:
            continue
        if flag not in out:
            out[flag] = meaning
    return out


def build_structured_flag_explanations(command: str, raw: Any, ui_lang: str) -> List[Tuple[str, str]]:
    flags_in_command = extract_flags_from_command(command)
    provided = normalize_flag_explanations(raw)

    out: List[Tuple[str, str]] = []
    for flag in flags_in_command:
        meaning = provided.get(flag, "").strip()
        if not meaning:
            meaning = t(ui_lang, "missing_flag_explanation")
        out.append((flag, meaning))
    return out


def main() -> int:
    configure_stdio()
    args = parse_args(sys.argv[1:])
    conf = load_config()
    if args.mode == "config":
        return handle_config(args, conf)

    request = " ".join(args.prompt).strip()
    ui_lang = classify_request_language(request)
    if not request:
        print(t(ui_lang, "empty_request"), file=sys.stderr)
        return 2

    provider, model, base_url, api_key = resolve_runtime_config(args, conf)
    cwd = os.getcwd()
    system_prompt = build_system_prompt(cwd)
    user_prompt = f"Request: {request}"

    try:
        raw = call_provider(provider, base_url, api_key, model, system_prompt, user_prompt, ui_lang)
        parsed = extract_json(raw)
    except Exception as err:
        print(t(ui_lang, "llm_error", error=err), file=sys.stderr)
        return 1

    ui_lang = normalize_model_language(parsed.get("language")) or ui_lang

    explanation = str(parsed.get("explanation", "")).strip()
    command = str(parsed.get("command", "")).strip()
    flag_explanations = build_structured_flag_explanations(
        command, parsed.get("flag_explanations"), ui_lang
    )
    warnings: List[str] = []
    if isinstance(parsed.get("warnings"), list):
        warnings = [str(w).strip() for w in parsed["warnings"] if str(w).strip()]

    if not command:
        print(t(ui_lang, "invalid_command", parsed=parsed), file=sys.stderr)
        return 1

    if explanation:
        print(explanation)
    if flag_explanations:
        print(t(ui_lang, "flag_header"))
        for flag, meaning in flag_explanations:
            print(f"- {flag}: {meaning}")
    if warnings:
        print(t(ui_lang, "warnings_header"))
        for item in warnings:
            print(f"- {item}")

    print(t(ui_lang, "enter_to_run"))
    print(t(ui_lang, "ctrl_c"))
    if "\n" in command or "\r" in command:
        print(t(ui_lang, "multiline_edit_hint"))
    print(t(ui_lang, "suggestion"))
    print(command)

    if args.print_only:
        return 0

    try:
        entered = editable_input("\n$ ", command)
    except KeyboardInterrupt:
        print(t(ui_lang, "cancelled"))
        return 130

    # Enter ohne Text fuehrt den vorgeschlagenen Befehl aus.
    final_command = entered.strip() if entered.strip() else command

    append_to_shell_history(final_command)

    cd_target = parse_plain_cd(final_command)
    if cd_target is not None:
        try:
            os.chdir(cd_target)
        except OSError as err:
            print(t(ui_lang, "cd_error", error=err), file=sys.stderr)
            return 1

        if sys.stdin.isatty() and sys.stdout.isatty():
            shell = os.getenv("SHELL") or shutil.which("bash") or "/bin/sh"
            print(t(ui_lang, "changed_dir", cwd=os.getcwd()))
            print(t(ui_lang, "start_subshell"))
            os.execvp(shell, [shell, "-i"])

        print(t(ui_lang, "cd_parent_shell", cwd=os.getcwd()))
        return 0

    print(t(ui_lang, "stdout_stderr"))
    try:
        completed = subprocess.run(final_command, shell=True, check=False)
    except KeyboardInterrupt:
        # Ctrl+C waehrend laufendem Befehl (z. B. watch) ohne Python-Traceback beenden.
        return 130
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
