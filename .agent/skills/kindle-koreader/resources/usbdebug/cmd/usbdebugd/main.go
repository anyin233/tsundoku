package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	pidFilePath    = "/var/tmp/usbdebugd.pid"
	statusFilePath = "/var/tmp/usbdebugd.status"
	dropbearBin    = "/mnt/us/koreader/dropbear"
	dropbearDir    = "/mnt/us/koreader"
	dropbearLog    = "/var/tmp/usbdebugd_dropbear.log"
	sshPort        = "2222"
)

func logf(format string, args ...any) {
	ts := time.Now().Format("15:04:05")
	fmt.Printf("[%s usbdebugd] "+format+"\n", append([]any{ts}, args...)...)
}

func readRunningPID() int {
	raw, err := os.ReadFile(pidFilePath)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 || pid == os.Getpid() {
		return 0
	}
	cmdline, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return 0
	}
	if bytes.Contains(cmdline, []byte("usbdebugd")) {
		return pid
	}
	return 0
}

func ensureBaseFirewall() {
	rules := [][]string{
		{"INPUT", "1", "-i", "lo", "-j", "ACCEPT"},
		{"OUTPUT", "1", "-o", "lo", "-j", "ACCEPT"},
		{"INPUT", "1", "-p", "tcp", "--dport", sshPort, "-j", "ACCEPT"},
		{"OUTPUT", "1", "-p", "tcp", "--sport", sshPort, "-j", "ACCEPT"},
	}
	for _, r := range rules {
		delArgs := append([]string{"-D", r[0]}, r[2:]...)
		insArgs := append([]string{"-I"}, r...)
		_ = exec.Command("iptables", delArgs...).Run()
		_ = exec.Command("iptables", insArgs...).Run()
	}
}

func isSSHListening() bool {
	c, err := net.DialTimeout("tcp", "127.0.0.1:"+sshPort, 400*time.Millisecond)
	if err != nil {
		return false
	}
	_ = c.Close()
	return true
}

func ensureDropbear() {
	if isSSHListening() {
		return
	}
	_ = os.MkdirAll(filepath.Join(dropbearDir, "settings", "SSH"), 0755)
	_ = os.Chmod(dropbearBin, 0755)

	logFile, _ := os.OpenFile(dropbearLog, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	cmd := exec.Command(dropbearBin, "-E", "-R", "-p", sshPort, "-P", "/tmp/dropbear_koreader.pid", "-n")
	cmd.Dir = dropbearDir
	if logFile != nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
	}
	if err := cmd.Start(); err != nil {
		logf("failed to start dropbear: %v", err)
		if logFile != nil {
			_ = logFile.Close()
		}
		return
	}
	logf("started dropbear pid=%d on :%s", cmd.Process.Pid, sshPort)
	go func() {
		err := cmd.Wait()
		if logFile != nil {
			_ = logFile.Close()
		}
		if err != nil {
			logf("dropbear exited: %v", err)
		}
	}()
}

func koreaderRunning() bool {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false
	}
	self := strconv.Itoa(os.Getpid())
	for _, e := range entries {
		name := e.Name()
		if name == self || name == "" || name[0] < '0' || name[0] > '9' {
			continue
		}
		data, err := os.ReadFile(filepath.Join("/proc", name, "cmdline"))
		if err != nil || len(data) == 0 {
			continue
		}
		if bytes.Contains(data, []byte("reader.lua")) || bytes.Contains(data, []byte("koreader.sh")) {
			return true
		}
	}
	return false
}

func writeStatus(st *gadgetState) {
	var b strings.Builder
	fmt.Fprintf(&b, "mode=%s\n", st.Mode)
	if st.Ifname != "" {
		fmt.Fprintf(&b, "ifname=%s\n", st.Ifname)
	}
	fmt.Fprintf(&b, "ip=%s\n", st.IP)
	fmt.Fprintf(&b, "port=%s\n", sshPort)
	fmt.Fprintf(&b, "vid=%s\n", st.VID)
	fmt.Fprintf(&b, "pid=%s\n", st.PID)
	fmt.Fprintf(&b, "udc=%s\n", st.UDC)
	fmt.Fprintf(&b, "daemon_pid=%d\n", os.Getpid())
	_ = os.WriteFile(statusFilePath, []byte(b.String()), 0644)
}

func cmdDaemon() int {
	if existing := readRunningPID(); existing > 0 {
		logf("already running with pid=%d; keeping session alive", existing)
		return 0
	}
	if err := os.WriteFile(pidFilePath, []byte(strconv.Itoa(os.Getpid())+"\n"), 0644); err != nil {
		logf("failed to write pidfile: %v", err)
		return 1
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	writeProbeLog()
	ensureBaseFirewall()
	ensureDropbear()

	st, err := startUSBGadget(ctx, logf)
	if err != nil {
		logf("startUSBGadget failed: %v", err)
		_ = os.Remove(pidFilePath)
		return 1
	}
	writeStatus(st)

	defer func() {
		cancel()
		teardownGadget(st, logf)
		_ = os.Remove(statusFilePath)
		_ = os.Remove(pidFilePath)
		logf("stopped and released UDC cleanly")
	}()

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	missCount := 0
	seenKOReader := koreaderRunning()

	for {
		select {
		case sig := <-sigCh:
			logf("received signal %v; shutting down", sig)
			return 0
		case <-ticker.C:
			ensureDropbear()
			if st.Ifname != "" {
				ensureNetIfConfigured(st.Ifname, logf)
			}
			if koreaderRunning() {
				seenKOReader = true
				missCount = 0
			} else if seenKOReader {
				missCount++
				if missCount >= 4 {
					logf("KOReader absent for 8s; tearing down USB debug gadget")
					return 0
				}
			}
		}
	}
}

func cmdStop() int {
	pid := readRunningPID()
	if pid > 0 {
		_ = syscall.Kill(pid, syscall.SIGTERM)
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if readRunningPID() == 0 {
				logf("stopped usbdebugd pid=%d", pid)
				return 0
			}
			time.Sleep(100 * time.Millisecond)
		}
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	teardownGadget(nil, logf)
	_ = os.Remove(statusFilePath)
	_ = os.Remove(pidFilePath)
	return 0
}

func cmdStatus() int {
	pid := readRunningPID()
	fmt.Printf("running=%v pid=%d\n", pid > 0, pid)
	if data, err := os.ReadFile(statusFilePath); err == nil {
		fmt.Print(string(data))
	}
	if entries, err := os.ReadDir("/sys/class/udc"); err == nil {
		for _, e := range entries {
			st, _ := os.ReadFile(filepath.Join("/sys/class/udc", e.Name(), "state"))
			fmt.Printf("udc_%s_state=%s\n", e.Name(), strings.TrimSpace(string(st)))
		}
	}
	return 0
}

func main() {
	sub := "daemon"
	if len(os.Args) > 1 {
		sub = os.Args[1]
	}
	switch sub {
	case "daemon":
		os.Exit(cmdDaemon())
	case "stop":
		os.Exit(cmdStop())
	case "status":
		os.Exit(cmdStatus())
	default:
		fmt.Fprintf(os.Stderr, "Usage: %s [daemon|stop|status]\n", os.Args[0])
		os.Exit(2)
	}
}
