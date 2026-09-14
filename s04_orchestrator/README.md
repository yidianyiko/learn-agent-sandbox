# s04: Control plane, data plane, never mixed

[English](README.md) · [中文](README.zh.md)

[s00](../s00_shared_kernel/) → [s01](../s01_first_microvm/) → [s02](../s02_write_a_vmm/) → [s03](../s03_snapshot_restore/) → **s04** → s05 → ... → s08

> **Needs:** `/dev/kvm`, Go, the fetched assets.
> **Time:** about 30 minutes.

> *"Control plane, data plane, never mixed."*

---

## The Problem

You can start a microVM ([s01](../s01_first_microvm/)), you know what one is made of
([s02](../s02_write_a_vmm/)), and you can freeze and revive it
([s03](../s03_snapshot_restore/)). All of that was one machine, started by hand, watched
by you.

Now start a second one. And a tenth. Something has to remember which exist, hand out
names, and clean up after the ones that stop.

The tempting shape is a supervisor: a process that owns the machines, holds them in a
map, and proxies work to them. It is the wrong shape, and the reason is not a matter of
taste — it is a property of what a microVM actually is.

---

## Part 1 · What a microVM does when you shoot its supervisor

```bash
./orphans.sh
```

Two VMs are started by a parent process, which is then killed with `SIGKILL` — no
cleanup, no chance to react, the way a real crash goes.

```
1 · Two microVMs under a supervisor

   supervisor pid 91670
       PID    PPID STAT COMMAND
     91672   91670 Sl   firecracker
     91711   91670 Sl   firecracker

2 · Kill the supervisor — SIGKILL, no cleanup, no warning

   supervisor: gone

3 · The machines

       PID    PPID STAT COMMAND
     91672       1 Sl   firecracker
     91711       1 Sl   firecracker

4 · Can anyone still control them?

   vm1  GET /  -> HTTP 200
   vm2  GET /  -> HTTP 200
```

**`PPID` went from the supervisor to `1`.** Both machines were adopted by init, kept
running, and kept answering their API sockets. Neither noticed.

This is [s02](../s02_write_a_vmm/)'s name paying off. KVM is **Kernel**-based: a virtual
machine is a process, so it is scheduled, owned, orphaned and reparented like any other
process on the box. Nothing about it is special enough to die when its launcher does.

### Which tells you what the supervisor was

It was **bookkeeping, not plumbing**. No guest traffic passed through it, so losing it
cost nothing that was running. That separation is worth having on purpose:

```
control plane   which sandboxes exist, who asked for them, when to stop them
                low traffic · must be correct · may restart

data plane      the machines themselves, doing the work
                high traffic · must be fast · must not care about the above
```

Mix them — proxy guest I/O through the process that also serves your API — and a slow
API call stalls a workload, and a crash in your HTTP handler takes down every sandbox on
the host.

### And it tells you the cost

Those two machines are still holding 128 MiB each and still answering their sockets, and
the table that knew their names died with the supervisor. **They are orphans.** Nothing
will ever stop them, because nothing knows they are there.

So a control plane cannot keep the truth in its own memory. It has to write it down
somewhere that survives, and it has to be able to walk back in and recognise what it
finds.

---

## Part 2 · A control plane that can be killed

`main.go` is about 260 lines of Go with no dependencies. It exposes four endpoints:

```
POST   /sandbox       start one
GET    /sandbox       list the ones that are actually running
GET    /sandbox/{id}  one of them
DELETE /sandbox/{id}  stop it and forget it
```

```bash
./demo.sh
```

```
1 · Start the control plane, create two sandboxes
   control plane pid 99415
   POST /sandbox -> dlezmbghkrb2
   POST /sandbox -> dlezmbhltdje

2 · What is on disk  (the part that survives)
   dlezmbghkrb2.json
   dlezmbghkrb2.sock
   dlezmbhltdje.json
   dlezmbhltdje.sock

3 · Kill the control plane
   control plane: gone
   GET /sandbox : connection refused

   the machines:
       PID    PPID STAT COMMAND
     99427       1 Sl   firecracker
     99435       1 Sl   firecracker

4 · Start a new control plane
   adopted 2 sandbox(es) already running

5 · Kill one machine behind its back, then ask again
   killed pid 99427 directly, without telling the control plane
   [{"id":"dlezmbhltdje", ...}]
   reconcile: dlezmbghkrb2 is gone, forgetting it
```

The API went away and came back. The machines never knew.

---

## How It Works

### The store is deliberately dull

One JSON file per sandbox, in a directory:

```json
{
  "id": "dlezmbghkrb2",
  "pid": 99427,
  "sock": "/tmp/s04-state/dlezmbghkrb2.sock",
  "created": "2026-09-14T20:03:24.384141754+09:00"
}
```

No database. The lesson here is *"state must outlive the process"*, and a directory of
files says that without teaching anyone a schema. It is also readable with `cat`, which
matters more in a tutorial than it does in production.

### The eight lines that matter most

```go
func alive(sb Sandbox) bool {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", sb.PID))
	if err != nil {
		return false
	}
	return bytes.Contains(b, []byte(sb.Sock))
}
```

The obvious implementation is `syscall.Kill(pid, 0)` — does a process with that number
exist? **That answers the wrong question.**

PIDs are recycled. You wrote down 99427; that process died; the counter wrapped and 99427
now belongs to somebody's compiler. A control plane that only checks whether the number
is taken will report `cc` as a running microVM, and eventually `SIGKILL` it.

So we read the process's command line and require our own socket path to be in it.
Firecracker was launched as `firecracker --api-sock <that exact path>`, so this is an
identity check rather than an existence check.

### Reconciliation, not memory

```go
func reconcile() []Sandbox {
	// walk the directory, check each one, forget the dead
}
```

Called at startup **and on every `GET /sandbox`**. The process never caches "I believe
there are two". Every answer is the result of looking again.

That is why step 5 works: a machine killed behind the control plane's back is noticed the
next time anyone asks, rather than never. It is also the shape Kubernetes is built
from — a controller that observes the world and converges on the desired state, instead
of assuming its last write succeeded.

### Talking HTTP to a file

```go
Transport: &http.Transport{
	DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", sock)
	},
},
```

Replace the transport's dialler, ignore the network and address it is handed, and connect
to a unix socket instead. Requests are still written as `http://localhost/boot-source` —
that hostname is as fictional here as it was in `curl --unix-socket`.

### Start, do not run, and do not kill

```go
cmd.Start()                      // returns immediately; Run would block until exit
sb.PID = cmd.Process.Pid
go func() { _ = cmd.Wait() }()   // reap it when it eventually dies
```

`Wait` in a goroutine keeps exited children from lingering as zombies while we are alive.

What is missing is deliberate: **nothing kills the children when the control plane
exits.** Part 1 established that is not its job.

### Write it down only once it is real

```go
	// after all four VMM calls have succeeded:
	return sb, save(sb)
```

A state file for a sandbox that failed to start is worse than no state file — the next
control plane would adopt something that was never there.

---

## Try It

```bash
./orphans.sh    # part 1: the supervisor dies, the machines do not
./demo.sh       # part 2: a control plane that can be replaced mid-flight

# or drive it yourself
go run . -state /tmp/sbx &
curl -X POST     localhost:8080/sandbox
curl             localhost:8080/sandbox
curl -X DELETE   localhost:8080/sandbox/<id>
```

Worth doing next:

- Start a sandbox, then `cat` its state file and `ps` its pid. Everything the control
  plane knows is in those two places.
- Edit a state file to a pid that does not exist, then `GET /sandbox`. Watch it get
  forgotten.
- Edit one to a pid that **does** exist but is not firecracker — your shell, say. It is
  still forgotten, because `alive` checks identity and not existence. Now delete the
  `bytes.Contains` line and try again to see what the naive version would have done.

---

## What You Just Learned

1. **A microVM outlives whatever started it**, because it is a process and processes get
   reparented to init. The orchestrator is a registry, not a supervisor.

2. **Separating the planes is free protection.** Nothing flows through the control plane,
   so it can crash, be upgraded, or be restarted with zero effect on running work.

3. **The price of that freedom is amnesia.** A control plane that keeps truth in memory
   loses it on the way down and orphans everything it was managing.

4. **So do not remember — look.** State on disk, liveness from `/proc`, identity checked
   rather than assumed, and every answer recomputed. That is reconciliation, and it is
   why this 260-line program survives being shot.

---

## Going Deeper

- **[`e2b-dev/runtime`](https://github.com/e2b-dev/runtime)** splits exactly this way:
  `packages/api` takes requests and records intent, `packages/orchestrator` owns the VMMs
  on each node. The split you just built is the same one, minus the parts that make it
  survive a datacentre.
- **`jailer`**, in the Firecracker release tarball, is what a production control plane
  actually launches: it puts each VMM in its own chroot, namespaces and cgroup before
  `exec`ing it. The `exec.Command` here is the same call with none of the confinement.
- **PID namespaces and `pidfd`.** Linux offers `pidfd_open(2)`, a file descriptor that
  refers to a process rather than a number, which is immune to the recycling problem the
  `alive` check works around by hand.

---

**Next:** s05 — *Fork the machine, not the process* *(not yet written)*
s03 left a snapshot that can be restored any number of times. Now restore it ten times at
once.
