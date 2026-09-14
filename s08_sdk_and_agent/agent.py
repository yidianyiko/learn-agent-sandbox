#!/usr/bin/env python3
"""agent.py — a coding agent whose hands are a microVM you built.

The loop is the whole thing, and it is short:

    ask the model  ->  it asks for a command  ->  run it in the sandbox
                   ->  hand back the output   ->  repeat until it stops

Everything underneath — KVM, snapshots, vsock, tap devices — is the
previous eight chapters, reached through `sandbox.Sandbox`.

With ANTHROPIC_API_KEY set this talks to Claude. Without one it runs a
scripted stand-in, so the loop is still visible and CI still passes.

    python3 agent.py "count the lines of /etc/passwd"
"""

from __future__ import annotations

import os
import sys

from sandbox import Sandbox

MODEL = "claude-opus-5"
MAX_TURNS = 12

TOOLS = [{
    "name": "run_command",
    "description": (
        "Run one shell command inside the sandbox and return its output. "
        "The sandbox is a microVM with BusyBox; it is yours to change and "
        "is destroyed afterwards."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "command": {"type": "string", "description": "the shell command to run"},
        },
        "required": ["command"],
        "additionalProperties": False,
    },
    "strict": True,
}]

SYSTEM = (
    "You work inside a disposable Linux microVM with a BusyBox userland. "
    "Use run_command to look around and to do the work. Prefer small, "
    "checkable steps. When the task is done, say so plainly and stop."
)

BOLD, DIM, CYAN, OFF = "\033[1m", "\033[2m", "\033[36m", "\033[0m"
if not sys.stdout.isatty():
    BOLD = DIM = CYAN = OFF = ""


class ScriptedModel:
    """Stands in for Claude when no key is configured.

    It exists so the loop below can be read and run by anyone. The shape of
    what it returns is the shape the real API returns.
    """

    def __init__(self) -> None:
        self._turns = [
            [{"type": "tool_use", "id": "a", "name": "run_command",
              "input": {"command": "uname -r; ls /usr/bin | wc -l"}}],
            [{"type": "tool_use", "id": "b", "name": "run_command",
              "input": {"command": "printf 'n=0\\nfor f in /usr/bin/*; do n=$((n+1)); done\\n"
                                   "echo \"counted $n\"\\n' > /tmp/count.sh && sh /tmp/count.sh"}}],
            [{"type": "text", "text":
              "I wrote a script into the sandbox and ran it; the count above matches "
              "what ls reported, so the environment is behaving."}],
        ]
        self.n = 0

    def __call__(self, _messages):
        content = self._turns[min(self.n, len(self._turns) - 1)]
        self.n += 1
        stop = "tool_use" if content[0]["type"] == "tool_use" else "end_turn"
        return type("Reply", (), {"content": content, "stop_reason": stop})()


def make_model():
    """Return something callable that takes messages and returns a reply."""
    if not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")):
        print(f"{DIM}no ANTHROPIC_API_KEY — using a scripted stand-in "
              f"so the loop still runs{OFF}\n")
        return ScriptedModel(), False
    try:
        import anthropic
    except ImportError:
        print(f"{DIM}anthropic not installed (pip install anthropic) — "
              f"using the scripted stand-in{OFF}\n")
        return ScriptedModel(), False

    client = anthropic.Anthropic()

    def call(messages):
        return client.messages.create(
            model=MODEL,
            max_tokens=8000,
            system=SYSTEM,
            tools=TOOLS,
            thinking={"type": "adaptive"},
            messages=messages,
        )

    return call, True


def blocks(content):
    """The API returns objects; the stand-in returns dicts. Read both."""
    for b in content:
        yield b if isinstance(b, dict) else b.model_dump()


def main() -> int:
    task = " ".join(sys.argv[1:]) or "find out how many commands this machine has, then verify it with a script you write"
    model, real = make_model()

    print(f"{BOLD}task{OFF}  {task}\n")

    with Sandbox() as sbx:
        print(f"{DIM}sandbox {sbx.id} up{OFF}\n")
        messages = [{"role": "user", "content": task}]

        for turn in range(MAX_TURNS):
            reply = model(messages)

            # Append the assistant turn whole. With adaptive thinking the
            # response carries thinking blocks that must be echoed back
            # unchanged; picking out only the text would drop them.
            messages.append({"role": "assistant", "content": reply.content})

            calls = [b for b in blocks(reply.content) if b.get("type") == "tool_use"]
            for b in blocks(reply.content):
                if b.get("type") == "text" and b.get("text"):
                    print(f"{CYAN}{b['text'].strip()}{OFF}\n")

            if reply.stop_reason != "tool_use" or not calls:
                break

            # Every tool_result for one assistant turn goes back in ONE user
            # message. Splitting them teaches the model to stop batching.
            results = []
            for call in calls:
                command = call["input"]["command"]
                print(f"   {DIM}${OFF} {command}")
                out = sbx.run(command)
                shown = out.stdout if len(out.stdout) < 600 else out.stdout[:600] + "\n…"
                print("".join(f"     {line}\n" for line in shown.splitlines()) or "     \n")
                results.append({
                    "type": "tool_result",
                    "tool_use_id": call["id"],
                    "content": out.stdout or "(no output)",
                    "is_error": out.exit_code != 0,
                })
            messages.append({"role": "user", "content": results})
        else:
            print(f"{DIM}stopped after {MAX_TURNS} turns{OFF}")

    print(f"{DIM}sandbox destroyed{OFF}")
    if not real:
        print(f"\n{DIM}That was the stand-in. Set ANTHROPIC_API_KEY and run again "
              f"to let Claude drive the same loop.{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
