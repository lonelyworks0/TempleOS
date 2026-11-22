//go:build linux

package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// runQEMU starts QEMU and waits. The launcher stays as the parent so it can
// start again without the PC speaker if QEMU rejects the audio device and
// exits. macOS replaces this process instead; see proc_unix.go.
func runQEMU(qemu string, args []string, env []string) error {
	err := runOnce(qemu, args, env)
	var quick *quickExit
	if errors.As(err, &quick) && hasAudio(args) {
		return runOnce(qemu, withoutAudio(args), env)
	}
	return err
}

type quickExit struct{ msg string }

func (e *quickExit) Error() string { return e.msg }

func runOnce(qemu string, args []string, env []string) error {
	var stderr bytes.Buffer
	cmd := exec.Command(qemu, args...)
	cmd.Env = env
	cmd.Stdout = os.Stdout
	cmd.Stderr = io.MultiWriter(os.Stderr, &stderr)
	start := time.Now()
	if err := cmd.Run(); err != nil {
		if sig, ok := exitSignal(err); ok {
			os.Exit(128 + sig)
		}
		msg := fmt.Sprintf("QEMU failed: %v\n%s", err, stderr.String())
		if time.Since(start) < 5*time.Second {
			return &quickExit{msg}
		}
		return errors.New(msg)
	}
	return nil
}

func exitSignal(err error) (int, bool) {
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		return 0, false
	}
	ws, ok := ee.Sys().(syscall.WaitStatus)
	if !ok || !ws.Signaled() {
		return 0, false
	}
	return int(ws.Signal()), true
}

func startQEMU(qemu string, args []string, env []string) (*exec.Cmd, error) {
	cmd := exec.Command(qemu, args...)
	cmd.Env = env
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd, cmd.Start()
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "TempleOS: "+format+"\n", a...)
	os.Exit(1)
}
