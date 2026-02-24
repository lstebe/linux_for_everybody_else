#!/usr/bin/env python3
"""lfe: natural language to shell command helper."""

from __future__ import annotations

import argparse
import json
import os
import platform
import readline
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Tuple


SYSTEM_PROMPT = """Du bist lfe, ein Linux-Shell-Assistent.
Antworte ausschliesslich als valides JSON-Objekt ohne Markdown.
Nutze exakt dieses Schema:
{
  "explanation": "kurze Erklaerung in der Sprache der Anfrage",
  "command": "ein einzelner Linux-Befehl, der direkt im aktuellen Ordner funktioniert",
  "flag_explanations": [
    {"flag": "-x", "meaning": "Bedeutung von -x"},
    {"flag": "--example", "meaning": "Bedeutung von --example"}
  ],
  "warnings": ["optionale Warnung 1", "optionale Warnung 2"]
}
Regeln:
- Gib genau EINEN Befehl in "command" aus.
- Wenn der Befehl Flags nutzt, fuelle "flag_explanations" strukturiert mit genau diesen Flags.
- Wenn keine Flags genutzt werden, gib "flag_explanations": [] aus.
- Nutze sichere Defaults, wenn moeglich (z. B. erst anzeigen statt sofort loeschen), und erklaere das in explanation.
- Wenn der Befehl potenziell Dateien loescht, zeige in explanation wenn moeglich einen konkreten Dry-Run-Hinweis.
- Verwende relative Pfade (.) oder den uebergebenen cwd.
- Keine Backticks, kein zusaetzlicher Text, nur JSON.
"""


PROVIDERS = ("ollama", "openai", "claude")

DEFAULTS: Dict[str, Dict[str, str]] = {
    "ollama": {
        "base_url": "http://localhost:11434",
        "model": "llama3.2",
        "api_key": "",
    },
    "openai": {
        "base_url": "https://api.openai.com/v1",
        "model": "gpt-4o-mini",
        "api_key": "",
    },
    "claude": {
        "base_url": "https://api.anthropic.com/v1",
        "model": "claude-3-5-sonnet-latest",
        "api_key": "",
    },
}

ENV_KEYS: Dict[str, Dict[str, Tuple[str, ...]]] = {
    "ollama": {
        "base_url": ("OLLAMA_BASE_URL",),
        "model": ("OLLAMA_MODEL",),
        "api_key": ("OLLAMA_API_KEY",),
    },
    "openai": {
        "base_url": ("OPENAI_BASE_URL",),
        "model": ("OPENAI_MODEL",),
        "api_key": ("OPENAI_API_KEY",),
    },
    "claude": {
        "base_url": ("ANTHROPIC_BASE_URL", "CLAUDE_BASE_URL"),
        "model": ("CLAUDE_MODEL", "ANTHROPIC_MODEL"),
        "api_key": ("ANTHROPIC_API_KEY", "CLAUDE_API_KEY"),
    },
}


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
                "api_key": "",
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
            for key in ("base_url", "model", "api_key"):
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
        parser = argparse.ArgumentParser(prog="lfe config", description="lfe Konfiguration")
        sub = parser.add_subparsers(dest="config_cmd", required=True)
        sub.add_parser("path", help="Pfad zur Konfigurationsdatei anzeigen")
        sub.add_parser("show", help="Aktuelle Konfiguration anzeigen")
        set_parser = sub.add_parser("set", help="Wert setzen")
        set_parser.add_argument("key", help="z.B. provider, openai.model, openai.base_url, openai.token")
        set_parser.add_argument("value", help="Neuer Wert")
        unset_parser = sub.add_parser("unset", help="Wert leeren/zuruecksetzen")
        unset_parser.add_argument("key", help="z.B. openai.token, ollama.base_url")
        parsed = parser.parse_args(argv[1:])
        parsed.mode = "config"
        return parsed

    parser = argparse.ArgumentParser(
        prog="lfe", description="Natural language to Linux command via LLM."
    )
    parser.add_argument("prompt", nargs="*", help="Natuerliche Sprache fuer den Shell-Befehl")
    parser.add_argument(
        "--provider",
        choices=PROVIDERS,
        default=None,
        help="LLM-Provider (ueberschreibt Konfiguration fuer diesen Aufruf)",
    )
    parser.add_argument(
        "--model",
        default=None,
        help="Modellname (ueberschreibt Konfiguration fuer diesen Aufruf)",
    )
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="Befehl nur ausgeben, nicht interaktiv ausfuehren",
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
                parser.error("--provider erwartet einen Wert.")
            provider = argv[idx + 1]
            idx += 2
            continue
        if tok.startswith("--provider="):
            provider = tok.split("=", 1)[1]
            idx += 1
            continue
        if tok == "--model":
            if idx + 1 >= len(argv):
                parser.error("--model erwartet einen Wert.")
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
        parser.error("Natuerliche Sprache fuer den Shell-Befehl fehlt.")

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
    lines = ["."] if root.exists() else [f"<nicht gefunden: {root}>"]
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
            lines.append(f"{indent}- <zugriff verweigert: {err}>")
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
        lines.append(f"... (abgeschnitten nach {max_entries} Eintraegen)")
    return "\n".join(lines)


def build_system_prompt(cwd: str) -> str:
    distro = detect_distribution()
    home_path = str(Path.home())
    cwd_tree = render_tree(Path(cwd), max_depth=2, max_entries=200)
    context_block = (
        "\n\nLaufzeit-Kontext (fuer bessere, lokale Shell-Befehle):\n"
        f"- Distribution: {distro}\n"
        f"- Lokaler Arbeitspfad (cwd): {cwd}\n"
        f"- Home-Pfad: {home_path}\n"
        "- Tree (Tiefe 2) vom lokalen Arbeitspfad:\n"
        f"{cwd_tree}\n"
    )
    return SYSTEM_PROMPT + context_block


def http_post_json(url: str, payload: Dict[str, Any], headers: Dict[str, str]) -> Dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read().decode("utf-8")
            return json.loads(data)
    except urllib.error.HTTPError as err:
        error_body = err.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {err.code} von {url}: {error_body}") from err
    except urllib.error.URLError as err:
        raise RuntimeError(f"Netzwerkfehler bei {url}: {err}") from err


def call_ollama(base_url: str, model: str, system_prompt: str, user_prompt: str) -> str:
    payload = {
        "model": model,
        "stream": False,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "options": {"temperature": 0.1},
    }
    data = http_post_json(
        f"{base_url}/api/chat",
        payload,
        headers={"Content-Type": "application/json"},
    )
    return data.get("message", {}).get("content", "")


def call_openai(base_url: str, api_key: str, model: str, system_prompt: str, user_prompt: str) -> str:
    if not api_key:
        raise RuntimeError("OpenAI API-Token fehlt (setze openai.token oder OPENAI_API_KEY).")
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
    )
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as err:
        raise RuntimeError(f"Unerwartete OpenAI-Antwort: {data}") from err


def call_claude(base_url: str, api_key: str, model: str, system_prompt: str, user_prompt: str) -> str:
    if not api_key:
        raise RuntimeError("Claude API-Token fehlt (setze claude.token oder ANTHROPIC_API_KEY).")
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
    )
    try:
        blocks = data["content"]
        return "\n".join(block["text"] for block in blocks if block.get("type") == "text")
    except (KeyError, TypeError) as err:
        raise RuntimeError(f"Unerwartete Claude-Antwort: {data}") from err


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


def mask_secret(value: str) -> str:
    if not value:
        return ""
    if len(value) <= 6:
        return "*" * len(value)
    return f"{value[:4]}{'*' * (len(value) - 6)}{value[-2:]}"


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
    api_key = env_value(provider, "api_key") or provider_conf.get("api_key", "")
    return provider, model, base_url, api_key


def normalize_key(key: str) -> str:
    key = key.strip().lower()
    key = key.replace("apikey", "api_key")
    key = key.replace("token", "api_key")
    return key


def set_config_value(conf: Dict[str, Any], raw_key: str, value: str) -> None:
    key = normalize_key(raw_key)
    if key == "provider":
        if value not in PROVIDERS:
            raise ValueError(f"Ungueltiger Provider: {value}. Erlaubt: {', '.join(PROVIDERS)}")
        conf["provider"] = value
        return

    parts = key.split(".")
    if len(parts) != 2:
        raise ValueError(
            "Ungueltiger Key. Beispiele: provider, openai.model, openai.base_url, openai.token"
        )
    provider, field = parts
    if provider not in PROVIDERS:
        raise ValueError(f"Unbekannter Provider im Key: {provider}")
    if field not in ("model", "base_url", "api_key"):
        raise ValueError(f"Ungueltiges Feld im Key: {field}")
    conf["providers"][provider][field] = value


def unset_config_value(conf: Dict[str, Any], raw_key: str) -> None:
    key = normalize_key(raw_key)
    if key == "provider":
        conf["provider"] = "ollama"
        return

    parts = key.split(".")
    if len(parts) != 2:
        raise ValueError(
            "Ungueltiger Key. Beispiele: provider, openai.model, openai.base_url, openai.token"
        )
    provider, field = parts
    if provider not in PROVIDERS:
        raise ValueError(f"Unbekannter Provider im Key: {provider}")
    if field not in ("model", "base_url", "api_key"):
        raise ValueError(f"Ungueltiges Feld im Key: {field}")
    if field in ("model", "base_url"):
        conf["providers"][provider][field] = DEFAULTS[provider][field]
    else:
        conf["providers"][provider][field] = ""


def config_show(conf: Dict[str, Any]) -> str:
    out = normalize_config(conf)
    for provider in PROVIDERS:
        out["providers"][provider]["api_key"] = mask_secret(
            out["providers"][provider].get("api_key", "")
        )
    return json.dumps(out, ensure_ascii=True, indent=2)


def handle_config(args: argparse.Namespace, conf: Dict[str, Any]) -> int:
    if args.config_cmd == "path":
        print(config_path())
        return 0
    if args.config_cmd == "show":
        print(config_show(conf))
        return 0
    if args.config_cmd == "set":
        try:
            set_config_value(conf, args.key, args.value)
            save_config(conf)
        except ValueError as err:
            print(err, file=sys.stderr)
            return 2
        print(f"Gespeichert: {args.key}")
        return 0
    if args.config_cmd == "unset":
        try:
            unset_config_value(conf, args.key)
            save_config(conf)
        except ValueError as err:
            print(err, file=sys.stderr)
            return 2
        print(f"Zurueckgesetzt: {args.key}")
        return 0
    return 2


def call_provider(
    provider: str,
    base_url: str,
    api_key: str,
    model: str,
    system_prompt: str,
    user_prompt: str,
) -> str:
    if provider == "ollama":
        return call_ollama(base_url, model, system_prompt, user_prompt)
    if provider == "openai":
        return call_openai(base_url, api_key, model, system_prompt, user_prompt)
    if provider == "claude":
        return call_claude(base_url, api_key, model, system_prompt, user_prompt)
    raise RuntimeError(f"Provider nicht unterstuetzt: {provider}")


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


def build_structured_flag_explanations(command: str, raw: Any) -> List[Tuple[str, str]]:
    flags_in_command = extract_flags_from_command(command)
    provided = normalize_flag_explanations(raw)

    out: List[Tuple[str, str]] = []
    for flag in flags_in_command:
        meaning = provided.get(flag, "").strip()
        if not meaning:
            meaning = "Keine Erklaerung vom Modell geliefert."
        out.append((flag, meaning))
    return out


def main() -> int:
    configure_stdio()
    args = parse_args(sys.argv[1:])
    conf = load_config()
    if args.mode == "config":
        return handle_config(args, conf)

    request = " ".join(args.prompt).strip()
    if not request:
        print("Leere Anfrage.", file=sys.stderr)
        return 2

    provider, model, base_url, api_key = resolve_runtime_config(args, conf)
    cwd = os.getcwd()
    system_prompt = build_system_prompt(cwd)
    user_prompt = f"Anfrage: {request}"

    try:
        raw = call_provider(provider, base_url, api_key, model, system_prompt, user_prompt)
        parsed = extract_json(raw)
    except Exception as err:
        print(f"LLM-Fehler: {err}", file=sys.stderr)
        return 1

    explanation = str(parsed.get("explanation", "")).strip()
    command = str(parsed.get("command", "")).strip()
    flag_explanations = build_structured_flag_explanations(
        command, parsed.get("flag_explanations")
    )
    warnings: List[str] = []
    if isinstance(parsed.get("warnings"), list):
        warnings = [str(w).strip() for w in parsed["warnings"] if str(w).strip()]

    if not command:
        print(f"Keine gueltige command-Antwort vom Modell: {parsed}", file=sys.stderr)
        return 1

    if explanation:
        print(explanation)
    if flag_explanations:
        print("\nFlag-Erklaerungen:")
        for flag, meaning in flag_explanations:
            print(f"- {flag}: {meaning}")
    if warnings:
        print("\nWarnungen:")
        for item in warnings:
            print(f"- {item}")

    print("\nTippe Enter, um den Befehl auszufuehren (du kannst ihn vorher bearbeiten).")
    print("Ctrl+C zum Abbrechen.")
    print("\nVorschlag:")
    print(command)

    if args.print_only:
        return 0

    try:
        entered = editable_input("\n$ ", command)
    except KeyboardInterrupt:
        print("\nAbgebrochen.")
        return 130

    # Enter ohne Text fuehrt den vorgeschlagenen Befehl aus.
    final_command = entered.strip() if entered.strip() else command

    append_to_shell_history(final_command)

    cd_target = parse_plain_cd(final_command)
    if cd_target is not None:
        try:
            os.chdir(cd_target)
        except OSError as err:
            print(f"\ncd-Fehler: {err}", file=sys.stderr)
            return 1

        if sys.stdin.isatty() and sys.stdout.isatty():
            shell = os.getenv("SHELL") or shutil.which("bash") or "/bin/sh"
            print(f"\nWechsle nach: {os.getcwd()}")
            print("Starte Subshell. Mit 'exit' kommst du zurueck.")
            os.execvp(shell, [shell, "-i"])

        print(
            "\nHinweis: 'cd' kann das Eltern-Shell nicht direkt aendern. "
            f"Ziel waere: {os.getcwd()}"
        )
        return 0

    print("\nstdout/stderr:")
    completed = subprocess.run(final_command, shell=True, check=False)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
