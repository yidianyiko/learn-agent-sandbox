// sandboxd — a control plane for microVMs.
//
// Part 1 (orphans.sh) established the constraint this program is built
// around: a microVM is a process, it outlives the thing that started it,
// and nothing flows through the supervisor. So this is a registry, not a
// pipeline. It starts machines, writes down what it started, and can be
// killed and restarted without any of them noticing.
//
//	POST   /sandbox       start one
//	GET    /sandbox       list the ones that are actually running
//	GET    /sandbox/{id}  one of them
//	DELETE /sandbox/{id}  stop it and forget it
//
// Usage: go run . [-addr 127.0.0.1:8080] [-state ./state]
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"
	"time"
)

type Sandbox struct {
	ID      string    `json:"id"`
	PID     int       `json:"pid"`
	Sock    string    `json:"sock"`
	Log     string    `json:"log"`
	Created time.Time `json:"created"`
}

var (
	addr     = flag.String("addr", "127.0.0.1:8080", "address to serve the control plane on")
	stateDir = flag.String("state", "./state", "where to write down what is running")
	assets   = flag.String("assets", "../assets", "directory holding firecracker, the kernel and the rootfs")
)

// ---------------------------------------------------------------------
// The store. Deliberately the dullest possible thing: one JSON file per
// sandbox in a directory. It has to survive this process dying, which
// rules out memory, and it has to be inspectable with `cat`, which rules
// out anything clever.
// ---------------------------------------------------------------------

func statePath(id string) string { return filepath.Join(*stateDir, id+".json") }

func save(sb Sandbox) error {
	b, err := json.MarshalIndent(sb, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(statePath(sb.ID), b, 0o644)
}

func forget(id string) { os.Remove(statePath(id)) }

func load(id string) (Sandbox, error) {
	var sb Sandbox
	b, err := os.ReadFile(statePath(id))
	if err != nil {
		return sb, err
	}
	return sb, json.Unmarshal(b, &sb)
}

// alive answers "is MY sandbox still running", which is not the same
// question as "is there a process with that pid".
//
// PIDs are recycled. By the time we look, that number may belong to
// something else entirely, and a control plane that confuses the two will
// cheerfully report a compiler as a running microVM. So we read the
// process's command line and require our own socket path to be in it.
func alive(sb Sandbox) bool {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", sb.PID))
	if err != nil {
		return false
	}
	return bytes.Contains(b, []byte(sb.Sock))
}

// reconcile walks the directory and throws away entries whose process is
// gone. This is the whole idea: the orchestrator does not trust its own
// memory, it looks.
func reconcile() []Sandbox {
	entries, err := os.ReadDir(*stateDir)
	if err != nil {
		return nil
	}
	var live []Sandbox
	for _, e := range entries {
		if filepath.Ext(e.Name()) != ".json" {
			continue
		}
		id := e.Name()[:len(e.Name())-len(".json")]
		sb, err := load(id)
		if err != nil {
			continue
		}
		if alive(sb) {
			live = append(live, sb)
		} else {
			log.Printf("reconcile: %s is gone, forgetting it", id)
			forget(id)
		}
	}
	sort.Slice(live, func(i, j int) bool { return live[i].Created.Before(live[j].Created) })
	return live
}

// ---------------------------------------------------------------------
// Talking to one VMM. Firecracker's API is HTTP over a unix socket, so
// the only unusual part is teaching the client to dial a file.
// ---------------------------------------------------------------------

func vmmClient(sock string) *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", sock)
			},
		},
		Timeout: 5 * time.Second,
	}
}

func vmmPut(c *http.Client, path, body string) error {
	req, err := http.NewRequest(http.MethodPut, "http://localhost"+path, bytes.NewBufferString(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("PUT %s: %s", path, resp.Status)
	}
	return nil
}

// ---------------------------------------------------------------------
// Starting one.
// ---------------------------------------------------------------------

func start() (Sandbox, error) {
	id := strconv.FormatInt(time.Now().UnixNano(), 36)
	sb := Sandbox{
		ID:      id,
		Sock:    filepath.Join(*stateDir, id+".sock"),
		Log:     filepath.Join(*stateDir, id+".log"),
		Created: time.Now(),
	}

	logFile, err := os.Create(sb.Log)
	if err != nil {
		return sb, err
	}
	defer logFile.Close()

	cmd := exec.Command(filepath.Join(*assets, "firecracker"), "--api-sock", sb.Sock)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	if err := cmd.Start(); err != nil {
		return sb, err
	}
	sb.PID = cmd.Process.Pid

	// Reap the child when it eventually exits, so it does not linger as a
	// zombie while we are alive. We do not kill it when we exit — part 1
	// showed that is not our job.
	go func() { _ = cmd.Wait() }()

	// The socket appears a few milliseconds after the process does.
	c := vmmClient(sb.Sock)
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := os.Stat(sb.Sock); err == nil {
			break
		}
		if time.Now().After(deadline) {
			_ = cmd.Process.Kill()
			return sb, fmt.Errorf("firecracker never created %s", sb.Sock)
		}
		time.Sleep(5 * time.Millisecond)
	}

	abs, _ := filepath.Abs(*assets)
	steps := []struct{ path, body string }{
		{"/boot-source", fmt.Sprintf(`{"kernel_image_path":%q,"boot_args":"console=ttyS0 reboot=k panic=1"}`,
			filepath.Join(abs, "vmlinux-6.1.186"))},
		{"/drives/rootfs", fmt.Sprintf(`{"drive_id":"rootfs","path_on_host":%q,"is_root_device":true,"is_read_only":true}`,
			filepath.Join(abs, "ubuntu-24.04.squashfs"))},
		{"/machine-config", `{"vcpu_count":1,"mem_size_mib":256}`},
		{"/actions", `{"action_type":"InstanceStart"}`},
	}
	for _, s := range steps {
		if err := vmmPut(c, s.path, s.body); err != nil {
			_ = cmd.Process.Kill()
			return sb, err
		}
	}

	// Written down only once it is genuinely running. A state file for a
	// sandbox that failed to start is worse than no state file.
	return sb, save(sb)
}

func stop(sb Sandbox) {
	if alive(sb) {
		_ = syscall.Kill(sb.PID, syscall.SIGKILL)
	}
	forget(sb.ID)
	os.Remove(sb.Sock)
	os.Remove(sb.Log)
}

// ---------------------------------------------------------------------
// The API.
// ---------------------------------------------------------------------

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func main() {
	flag.Parse()
	if err := os.MkdirAll(*stateDir, 0o755); err != nil {
		log.Fatal(err)
	}

	// Before serving anything, look at what is actually out there. A
	// restarted control plane has no memory and must not pretend to.
	found := reconcile()
	log.Printf("adopted %d sandbox(es) already running", len(found))

	mux := http.NewServeMux()

	mux.HandleFunc("POST /sandbox", func(w http.ResponseWriter, r *http.Request) {
		sb, err := start()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		log.Printf("started %s (pid %d)", sb.ID, sb.PID)
		writeJSON(w, http.StatusCreated, sb)
	})

	mux.HandleFunc("GET /sandbox", func(w http.ResponseWriter, r *http.Request) {
		list := reconcile()
		if list == nil {
			list = []Sandbox{}
		}
		writeJSON(w, http.StatusOK, list)
	})

	mux.HandleFunc("GET /sandbox/{id}", func(w http.ResponseWriter, r *http.Request) {
		sb, err := load(r.PathValue("id"))
		if err != nil || !alive(sb) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "no such sandbox"})
			return
		}
		writeJSON(w, http.StatusOK, sb)
	})

	mux.HandleFunc("DELETE /sandbox/{id}", func(w http.ResponseWriter, r *http.Request) {
		sb, err := load(r.PathValue("id"))
		if err != nil {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "no such sandbox"})
			return
		}
		stop(sb)
		log.Printf("stopped %s", sb.ID)
		w.WriteHeader(http.StatusNoContent)
	})

	log.Printf("control plane on http://%s  state in %s", *addr, *stateDir)
	log.Fatal(http.ListenAndServe(*addr, mux))
}
