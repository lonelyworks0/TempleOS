// Command TempleOS-Linux-arm64-native runs this tree's HolyC in a Linux
// process, compiled to the host CPU. There is no QEMU and no x86 emulation.
//
// The first launch unpacks the HolyC runtime and its shared libraries into
// the user data directory. Later launches reuse that copy.
package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func main() {
	data, reset, rest := parseArgs(os.Args[1:])
	if data == "" {
		data = defaultDataDir()
	}
	dir, err := resourcesDir(data, reset)
	if err != nil {
		fatal("%v", err)
	}
	bin := filepath.Join(dir, "runtime", "bin", "templeos")
	if _, err := os.Stat(bin); err != nil {
		fatal("runtime is missing %s", bin)
	}
	env := os.Environ()
	lib := filepath.Join(dir, "runtime", "lib")
	if st, err := os.Stat(lib); err == nil && st.IsDir() {
		env = prependEnvPath(env, "LD_LIBRARY_PATH", lib)
	}
	argv := append([]string{bin}, rest...)
	if err := syscall.Exec(bin, argv, env); err != nil {
		fatal("starting the HolyC runtime: %v", err)
	}
}

// parseArgs recognizes the wrapper's own flags and forwards everything
// else, including --self-test, to the HolyC runtime.
func parseArgs(args []string) (data string, reset bool, rest []string) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--":
			rest = append(rest, args[i+1:]...)
			return
		case "-data", "--data":
			if i+1 >= len(args) {
				fatal("%s needs a directory", a)
			}
			i++
			data = args[i]
		case "-reset", "--reset":
			reset = true
		case "-h", "--help":
			fmt.Fprintf(os.Stderr, `Usage: %s [-data DIR] [-reset] [runtime flags]

Runs TempleOS as native machine code in a window (640x480, 16 colors).
No virtual machine is started.

  -data DIR     where the runtime is unpacked
                (default: $XDG_DATA_HOME/templeos-native or
                ~/.local/share/templeos-native)
  -reset        unpack the runtime again

Other flags are passed to the HolyC runtime. The ones used by CI and
the build notes are:

  --self-test FILE.ppm
      Boot the desktop, compile /Demo/Graphics/Box.HC from this tree,
      write the framebuffer, and exit. Exit status is 0 only when the
      picture is the TempleOS desktop.
  -c FILE.HC
      Run a HolyC file with no window. /Native/Bench.HC times a loop.
  -t DIR
      Use DIR as the boot drive instead of the built-in one.
`, filepath.Base(os.Args[0]))
			os.Exit(0)
		default:
			rest = append(rest, a)
		}
	}
	return
}

func defaultDataDir() string {
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return filepath.Join(d, "templeos-native")
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".local", "share", "templeos-native")
	}
	return "templeos-native-data"
}

func resourcesDir(dataDir string, reset bool) (string, error) {
	if len(payloadZip) == 0 {
		exe, err := os.Executable()
		if err != nil {
			return "", err
		}
		exe, _ = filepath.EvalSymlinks(exe)
		dir := filepath.Dir(exe)
		if _, err := os.Stat(filepath.Join(dir, "runtime", "bin", "templeos")); err == nil {
			return dir, nil
		}
		return "", fmt.Errorf("this binary has no embedded runtime and none sits beside it")
	}
	sum := sha256.Sum256(payloadZip)
	name := "runtime-" + hex.EncodeToString(sum[:6])
	dest := filepath.Join(dataDir, name)
	done := filepath.Join(dest, ".complete")
	if reset {
		os.RemoveAll(dest)
	}
	if _, err := os.Stat(done); err == nil {
		return dest, nil
	}
	zr, err := zip.NewReader(bytes.NewReader(payloadZip), int64(len(payloadZip)))
	if err != nil {
		return "", fmt.Errorf("damaged payload: %v", err)
	}
	tmp := dest + ".partial"
	os.RemoveAll(tmp)
	for _, f := range zr.File {
		path := filepath.Join(tmp, filepath.FromSlash(f.Name))
		if !strings.HasPrefix(path, tmp+string(os.PathSeparator)) && path != tmp {
			return "", fmt.Errorf("bad path in payload: %s", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(path, 0o755); err != nil {
				return "", err
			}
			continue
		}
		if err := extractFile(f, path); err != nil {
			return "", err
		}
	}
	os.RemoveAll(dest)
	if err := os.Rename(tmp, dest); err != nil {
		return "", err
	}
	if err := os.WriteFile(done, nil, 0o644); err != nil {
		return "", err
	}
	old, _ := filepath.Glob(filepath.Join(dataDir, "runtime-*"))
	for _, d := range old {
		if filepath.Base(d) != name {
			os.RemoveAll(d)
		}
	}
	return dest, nil
}

func extractFile(f *zip.File, path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	r, err := f.Open()
	if err != nil {
		return err
	}
	defer r.Close()
	mode := f.Mode()
	if mode&0o111 != 0 {
		mode |= 0o755
	} else {
		mode |= 0o644
	}
	w, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(w, r); err != nil {
		w.Close()
		return err
	}
	return w.Close()
}

func prependEnvPath(env []string, key, value string) []string {
	prefix := key + "="
	for i, e := range env {
		if strings.HasPrefix(e, prefix) {
			old := e[len(prefix):]
			if old != "" {
				value = value + string(os.PathListSeparator) + old
			}
			env[i] = prefix + value
			return env
		}
	}
	return append(env, prefix+value)
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "TempleOS: "+format+"\n", args...)
	os.Exit(1)
}
