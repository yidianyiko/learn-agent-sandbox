# s08: Now hand it to an agent

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/) → ... → [s06](../s06_in_vm_agent/) → [s07](../s07_networking/) → **s08**

> **Needs:** `/dev/kvm`, cargo, python3, the fetched assets.
> `ANTHROPIC_API_KEY` is optional — without it a scripted stand-in drives the same loop.
> **Time:** about 30 minutes.

> *"Now hand it to an agent."*

---

## The Problem

Everything works. A machine boots in under a second, freezes to two files, forks four ways
for the price of one, takes commands over a channel that needs no network, and can reach
the internet when you let it.

And nobody would use any of it, because using it means knowing about KVM ioctls, cpio
archives, vsock handshakes and copy-on-write memory.

The last chapter is about giving all of that away.

---

## Part 1 · The SDK

```python
from sandbox import Sandbox

with Sandbox() as sbx:
    print(sbx.run("uname -r").stdout)
    snap = sbx.snapshot()

for child in snap.fork(4):
    child.run("...")
```

```bash
python3 demo.py
```

```
1 · One sandbox
   booted in 789 ms   (id 9369132d6ebb)

   $ uname -r
     6.1.186
   $ free -m | awk 'NR==2{print $2" MB"}'
     230 MB

2 · Prepare an environment, then freeze it
   prepared: installed at 21:10:24
   snapshot: 256 MiB of memory in 425 ms

3 · Fork it four ways
   four machines in 97 ms total

   fork 1   shared: installed at 21:10:24   own: branch 1
   fork 2   shared: installed at 21:10:24   own: branch 2
   fork 3   shared: installed at 21:10:24   own: branch 3
   fork 4   shared: installed at 21:10:24   own: branch 4
```

Nothing in `sandbox.py` is new. It is s01 (boot), s03 (snapshot), s05 (fork), s06 (talk to
the agent) and s07 (network), arranged so the caller does not have to know that.

**Which is the only thing an SDK ever does: decide what you are allowed to stop thinking
about.** Every method here is a decision of that kind —

| Method | What it hides |
|---|---|
| `Sandbox()` | spawning a VMM, four API calls, building an initramfs, waiting for an agent to announce itself |
| `.run(cmd)` | the `CONNECT 1234\n` / `OK\n` handshake, and parsing `[exit N]` back out of the stream |
| `.snapshot()` | pausing first, then two files |
| `.fork(n)` | that restore is pre-boot only, and that the snapshot's vsock path must be overridden |

### Two details worth keeping

**Firecracker's API is HTTP over a unix socket, and Python's `http.client` will not dial
one.** Rather than add a dependency, `_api` writes the four lines of HTTP itself. It is
shorter than the import would have been.

**`/vm` is `PATCH`, not `PUT`.** Every other endpoint declares a resource; this one updates
the state of something that already exists. Getting that wrong returns a bare `400` with no
explanation, which cost a few minutes to find.

---

## Part 2 · The agent

```bash
python3 agent.py "find out how many commands this machine has, then verify it with a script you write"
```

```
task  find out how many commands this machine has, then verify it with a script you write

sandbox 0e032a994953 up

   $ uname -r; ls /usr/bin | wc -l
     6.1.186
     177

   $ printf 'n=0\nfor f in /usr/bin/*; do n=$((n+1)); done\necho "counted $n"\n' > /tmp/count.sh && sh /tmp/count.sh
     counted 177

I wrote a script into the sandbox and ran it; the count above matches what ls
reported, so the environment is behaving.

sandbox destroyed
```

The loop is the whole program, and it is short enough to read in one go:

```python
while True:
    reply = model(messages)
    messages.append({"role": "assistant", "content": reply.content})

    calls = [b for b in reply.content if b.type == "tool_use"]
    if reply.stop_reason != "tool_use" or not calls:
        break

    results = []
    for call in calls:
        out = sbx.run(call.input["command"])          # <- eight chapters, one line
        results.append({"type": "tool_result", "tool_use_id": call.id,
                        "content": out.stdout, "is_error": out.exit_code != 0})
    messages.append({"role": "user", "content": results})
```

Ask the model. It asks for a command. Run it in the sandbox. Hand back what happened.
Repeat until it stops asking.

**That is an agent.** The interesting engineering is not in this loop — it is in the line
that runs the command somewhere the model cannot damage.

### Three things that matter in those twenty lines

**Append `reply.content` whole, not just the text.** With adaptive thinking the response
carries thinking blocks that must be echoed back unchanged on the next request. Extracting
the text and appending that silently drops them.

**All `tool_result` blocks for one assistant turn go back in one user message.** Splitting
them across several messages teaches the model to stop asking for things in parallel.

**A failed command is a result, not an exception.** `is_error: true` with the actual
output, so the model can read the error and try something else — which is most of what
agents spend their time doing.

### Running without a key

With no `ANTHROPIC_API_KEY`, a scripted stand-in returns the same shape the API returns and
the loop runs unchanged. The point is that the loop is readable and testable without
spending anything; set the key and Claude drives the identical code.

---

## What the sandbox is for

[s05](../s05_fork_parallel/) argued that forking changes what an agent can do. Here is the
shape it enables, in the SDK's own terms:

```python
with Sandbox() as base:
    base.run("apk add gcc && git clone ... && make deps")   # once
    ready = base.snapshot()

attempts = ready.fork(4)                                    # 97 ms
for attempt, fix in zip(attempts, candidate_fixes):
    attempt.run(f"git apply {fix} && make test")
```

Four attempts against a prepared environment, none of which can see the others, for the
cost of preparing it once. Without forking this is four sequential setups; with it, the
setup happened before any of them existed.

---

## Try It

```bash
../scripts/fetch-assets.sh
make -C ../s06_in_vm_agent all

python3 demo.py                       # the SDK
python3 agent.py                      # the loop, with a stand-in
ANTHROPIC_API_KEY=... python3 agent.py "your task here"
```

Worth doing next:

- Give the agent a task it will fail at first. Watch it read the error and change approach
  — that feedback path is the whole reason the output goes back verbatim.
- Add a `write_file` tool beside `run_command`. You are now designing an agent's tool
  surface, which is the next problem after this repository's.
- Take a snapshot after the model's third command and fork it. The agent can now back up.

---

## What You Just Learned

1. **An SDK is a decision about ignorance.** Four methods, and the caller never learns what
   a vsock handshake is. Everything underneath is unchanged and still running.

2. **The agent loop is twenty lines.** Ask, run, report, repeat. Every hard part of this
   repository is behind one call inside it.

3. **The difficulty was never the loop.** It was building a place to run the commands where
   being wrong is cheap — which took eight chapters and is the only reason the twenty lines
   are safe to write.

---

## Where this ends and production begins

You now have, in about two thousand lines, something with the same shape as a commercial
agent sandbox. What a production system adds is not a missing idea — it is the
[red lines](../README.md#what-is-deliberately-left-out) this repository drew on purpose:
multi-tenancy, quotas, scheduling across machines, template builds, egress policy, and the
hardening that turns "works on my laptop" into "safe with strangers' code".

**Go read [`e2b-dev/runtime`](https://github.com/e2b-dev/runtime).** Every chapter here has
pointed at the file in it that does the same job properly. That codebase will read
differently now — not as an impenetrable production system, but as the version of your
toy that survived contact with everyone.

---

**That's the repository.** Back to [the beginning](../README.md).
