#!/usr/bin/env python3
"""Claude Code PreToolUse hook for Bash: a heavy step (a release build, a full test suite) isn't run
on this machine while it is busy and a peer machine sits idle; the message names the line that runs
it there. Self-test: python3 heavy-guard.py --test

Off unless ~/.claude/heavy-guard.json exists (format in the README): with no config, or one that
can't be read, every command is allowed and nothing is probed.

Blocked (exit 2) only when all hold:
  - the command runs a heavy step here (a config pattern in command position; quoted text, text
    heredocs and `ssh HOST '...'` don't count, `bash -c '...'` does);
  - this machine with the step's threads added is over BUSY per core: (load1 + threads) / cores;
  - a peer is under IDLE per core. Peers' loads are cached for CACHE_S; a stale cache is refreshed
    only when this machine is busy, with probes bounded to PROBE_S in all;
  - the step isn't already going through the configured runner, and HEAVY_LOCAL=1 isn't set (in
    the command or the environment).
No peer answering: allowed. A leading `cd DIR &&` is where the step runs ({dir} in the message).
Each block is a line in ~/.claude/toolkit-hits.log, like the other guards.
Test knobs (environment): HEAVY_GUARD_LOADAVG (a loadavg file), HEAVY_GUARD_CORES.
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

CACHE_S = 60
PROBE_S = 1.5
CLAUDE = Path.home() / ".claude"
CONFIG = CLAUDE / "heavy-guard.json"
CACHE = CLAUDE / "heavy-guard-load.json"
TEMPLATE = "ssh {host} {remote}"

# Where a command starts: the start, after a separator, $( / backtick, a subshell or group, after
# a wrapper (xargs, sudo, env, time, nohup, nice, timeout N), a shell keyword, or VAR=value prefixes.
START = (r"(?:^|[;&|`\n({!]|\$\(|\b(?:xargs|sudo|exec|nohup|env|time|nice|if|elif|then|else|while|until|do)\s"
         r"|\btimeout\s+\S+\s)\s*(?:\w+=\S*\s+)*")
OVERRIDE = re.compile(r"(?:^|[\s;&|(])(?:export\s+)?HEAVY_LOCAL=1\b")
QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")
HEREDOC = re.compile(r"^(?P<line>[^\n]*?<<-?[ \t]*(?P<q>['\"]?)(?P<tag>\w+)(?P=q)[^\n]*)\n(?P<body>.*?)^[ \t]*(?P=tag)[ \t]*$", re.M | re.S)
SHELL_INPUT = re.compile(r"(?:^|[;&|]\s*)(?:ba|z|da)?sh\b")
NESTED = re.compile(r"\b(?:ba|z|da)?sh\s+(?:-\w+\s+)*-c\s+('[^']*'|\"(?:\\.|[^\"\\])*\")")
LEAD_CD = re.compile(r"^\s*cd\s+(\S+)\s*&&\s*(.+)$", re.S)


def load_config(path: Path = CONFIG):
    try:
        c = json.loads(path.read_text())
        heavy = [(h["name"], int(h["threads"]), re.compile(START + h["pattern"])) for h in c.get("heavy", [])]
        runner = re.compile(c["runner"]) if c.get("runner") else None
    except (OSError, ValueError, KeyError, TypeError, re.error):
        return None
    return {"heavy": heavy, "runner": runner, "peers": [str(p) for p in c.get("peers", [])],
            "probe": c.get("probe"), "run_elsewhere": c.get("run_elsewhere") or TEMPLATE,
            "busy": float(c.get("busy", 0.6)), "idle": float(c.get("idle", 0.25))}


def local_text(command: str) -> str:
    """What of the command runs here: quoted text and text heredocs blanked, `bash -c '...'` kept,
    `ssh HOST '...'` (another machine's) blanked like any quote."""
    command = HEREDOC.sub(lambda m: m.group(0) if SHELL_INPUT.search(m.group("line")) else m.group("line"), command)
    nested = " ".join(m.group(1)[1:-1] for m in NESTED.finditer(command))
    return QUOTED.sub(lambda m: " " * len(m.group()), command) + "\n" + nested


def heavy_step(command: str, config):
    """(name, threads) of the heaviest step the command runs here, or None."""
    text = local_text(command)
    found = [(name, threads) for name, threads, rx in config["heavy"] if rx.search(text)]
    return max(found, key=lambda f: f[1]) if found else None


def local_load():
    try:
        path = os.environ.get("HEAVY_GUARD_LOADAVG")
        load = float(Path(path).read_text().split()[0]) if path else os.getloadavg()[0]
    except (OSError, ValueError, IndexError):
        return None
    return load, int(os.environ.get("HEAVY_GUARD_CORES") or os.cpu_count() or 1)


def run_bounded(commands: dict, end: float) -> dict:
    """{key: stdout or None}: every command at once, killed (with its children) at `end`."""
    procs, out = {}, {}
    for key, argv in commands.items():
        try:
            procs[key] = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                          stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        except OSError:
            out[key] = None
    for key, p in procs.items():
        try:
            text, _ = p.communicate(timeout=max(0.05, end - time.monotonic()))
            out[key] = text if p.returncode == 0 else None
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, 9)
            except OSError:
                pass
            p.wait()
            out[key] = None
    return out


def probe(config) -> dict:
    """{host: {load, cores} or None}: ssh peers (Linux) and/or the probe command's
    `HOST LOAD CORES` lines, PROBE_S in all."""
    commands = {h: ["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=1", h,
                    "cut -d' ' -f1 /proc/loadavg; nproc"] for h in config["peers"]}
    if config["probe"]:
        commands[None] = ["sh", "-c", config["probe"]]
    answers = run_bounded(commands, time.monotonic() + PROBE_S)
    boxes = {h: None for h in config["peers"]}  # no answer is cached too: the next command doesn't wait
    for host, text in answers.items():
        rows = [line.split() for line in (text or "").splitlines()] if host is None else [[host, *(text or "").split()]]
        for row in rows:
            try:
                boxes[row[0]] = {"load": float(row[1]), "cores": int(row[2])}
            except (ValueError, IndexError):
                pass
    return boxes


def peer_loads(config) -> dict:
    try:
        c = json.loads(CACHE.read_text())
        if time.time() - c["at"] <= CACHE_S and all(h in c["boxes"] for h in config["peers"]):
            return c["boxes"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    boxes = probe(config)
    try:
        tmp = CACHE.with_name(f"{CACHE.name}.{os.getpid()}")
        tmp.write_text(json.dumps({"at": int(time.time()), "boxes": boxes}))
        tmp.replace(CACHE)
    except OSError:
        pass
    return boxes


def where(command: str, cwd: str):
    """(directory, command, prefix): a leading `cd DIR &&` is where the step runs."""
    m = LEAD_CD.match(command)
    if m:
        target = Path(os.path.expanduser(m.group(1)))
        return str((Path(cwd or ".") / target).resolve()), m.group(2).strip(), f"cd {m.group(1)} && "
    return str(Path(cwd or ".").resolve()), command.strip(), ""


def decide(command: str, cwd: str = ".", config=None):
    """None to allow, else the message."""
    if config is None or os.environ.get("HEAVY_LOCAL") == "1":
        return None
    step = heavy_step(command, config)
    text = local_text(command)
    if not step or OVERRIDE.search(text) or (config["runner"] and config["runner"].search(text)):
        return None
    name, threads = step
    here = local_load()
    if not here:
        return None
    load, cores = here
    busy = (load + threads) / cores
    if busy <= config["busy"]:
        return None
    if not config["peers"] and not config["probe"]:
        return None
    idle = sorted((b["load"] / b["cores"], h) for h, b in peer_loads(config).items()
                  if isinstance(b, dict) and b.get("cores"))
    if not idle or idle[0][0] >= config["idle"]:
        return None
    per, host = idle[0]
    directory, run, _ = where(command, cwd)
    try:
        line = config["run_elsewhere"].format(
            host=host, dir=directory, command=run, threads=threads,
            remote=shlex.quote(f"cd {shlex.quote(directory)} && {run}"))
    except (KeyError, IndexError, ValueError):
        return None
    return (f"heavy-guard: {name} here would take this machine to {busy:.2f} per core (load {load:.1f} on "
            f"{cores} cores, +~{threads} threads) while {host} sits at {per:.2f}. Run it there:\n  {line}\n"
            f"To run it here anyway: HEAVY_LOCAL=1 {command}")


def self_test() -> int:
    data = json.loads((Path(__file__).parent / "heavy-guard.cases.json").read_text())
    config = load_config(Path(__file__).parent / "heavy-guard.cases.json")
    wrong = [cmd for want, cmd in data["cases"] if bool(heavy_step(cmd, config)) != (want == 2)]
    print(f"{len(data['cases']) - len(wrong)}/{len(data['cases'])} cases right" + "".join(f"\nwrong: {c!r}" for c in wrong))
    return 1 if wrong else 0


if __name__ == "__main__":
    if "--test" in sys.argv[1:]:
        sys.exit(self_test())
    config = load_config()
    if config is None:
        sys.exit(0)
    try:
        data = json.load(sys.stdin)
    except ValueError:
        sys.exit(0)
    try:
        why = decide(data.get("tool_input", {}).get("command", ""), data.get("cwd") or os.getcwd(), config)
    except Exception:  # a guard that can't decide lets the command run
        why = None
    if why:
        try:
            with open(CLAUDE / "toolkit-hits.log", "a") as log:
                log.write(f"{time.strftime('%Y-%m-%d')}\theavy-guard\t{why.split()[1]}\n")
        except OSError:
            pass
        print(f"Blocked: {why}", file=sys.stderr)
        sys.exit(2)
