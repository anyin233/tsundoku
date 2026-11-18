package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	configfsRoot = "/sys/kernel/config"
	gadgetBase   = "/sys/kernel/config/usb_gadget"
	gadgetName   = "koreader_dbg"
	gadgetDir    = "/sys/kernel/config/usb_gadget/koreader_dbg"
	probeLogPath = "/mnt/us/koreader/usb_probe.log"
)

type gadgetState struct {
	Mode   string
	Ifname string
	IP     string
	VID    string
	PID    string
	UDC    string
	FFS    *ffsSession
}

func runShellOut(name string, args ...string) string {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Sprintf("(%v) %s", err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out))
}

func writeProbeLog() {
	var b strings.Builder
	fmt.Fprintf(&b, "timestamp: %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "uname: %s\n", runShellOut("uname", "-a"))
	if pv, err := os.ReadFile("/etc/prettyversion.txt"); err == nil {
		fmt.Fprintf(&b, "prettyversion: %s\n", strings.TrimSpace(string(pv)))
	}

	b.WriteString("\n=== /sys/class/udc ===\n")
	if entries, err := os.ReadDir("/sys/class/udc"); err == nil {
		for _, e := range entries {
			st, _ := os.ReadFile(filepath.Join("/sys/class/udc", e.Name(), "state"))
			fmt.Fprintf(&b, "%s state=%s\n", e.Name(), strings.TrimSpace(string(st)))
		}
	} else {
		fmt.Fprintf(&b, "err: %v\n", err)
	}

	b.WriteString("\n=== /sys/kernel/config/usb_gadget ===\n")
	_ = filepath.Walk(gadgetBase, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			fmt.Fprintf(&b, "walk err %s: %v\n", p, err)
			return nil
		}
		if info.Mode()&os.ModeSymlink != 0 {
			tgt, _ := os.Readlink(p)
			fmt.Fprintf(&b, "%s -> %s\n", p, tgt)
		} else if info.IsDir() {
			fmt.Fprintf(&b, "%s/\n", p)
		} else {
			data, rerr := os.ReadFile(p)
			if rerr == nil && len(data) <= 256 {
				fmt.Fprintf(&b, "%s = %q\n", p, strings.TrimSpace(string(data)))
			} else {
				fmt.Fprintf(&b, "%s (unreadable/large)\n", p)
			}
		}
		return nil
	})

	b.WriteString("\n=== lsmod ===\n")
	b.WriteString(runShellOut("lsmod") + "\n")

	b.WriteString("\n=== mount ===\n")
	if m, err := os.ReadFile("/proc/mounts"); err == nil {
		b.Write(m)
	}

	b.WriteString("\n=== /lib/modules usb/gadget ===\n")
	b.WriteString(runShellOut("sh", "-c", "find /lib/modules -iname '*usb*' -o -iname '*gadget*' -o -iname '*ether*' -o -iname '*ncm*' -o -iname '*ecm*' -o -iname '*ffs*' 2>/dev/null | head -n 120") + "\n")

	_ = os.WriteFile(probeLogPath, []byte(b.String()), 0644)
}

func ensureConfigFS(logf func(string, ...any)) error {
	for _, mod := range []string{"libcomposite", "u_ether", "usb_f_ncm", "usb_f_ecm", "usb_f_ffs"} {
		_ = exec.Command("modprobe", mod).Run()
	}
	if _, err := os.Stat(gadgetBase); err == nil {
		return nil
	}
	_ = os.MkdirAll(configfsRoot, 0755)
	_ = exec.Command("mount", "-t", "configfs", "none", configfsRoot).Run()
	if _, err := os.Stat(gadgetBase); err != nil {
		return fmt.Errorf("configfs %s unavailable: %w", gadgetBase, err)
	}
	logf("mounted configfs at %s", configfsRoot)
	return nil
}

func findUDCName() (string, error) {
	entries, err := os.ReadDir("/sys/class/udc")
	if err != nil {
		return "", fmt.Errorf("read /sys/class/udc: %w", err)
	}
	for _, e := range entries {
		if e.Name() != "" {
			return e.Name(), nil
		}
	}
	return "", fmt.Errorf("no UDC found under /sys/class/udc")
}

func readKindleSerial() string {
	candidates := []string{
		filepath.Join(gadgetBase, "mtpgadget", "strings", "0x409", "serialnumber"),
		"/proc/usid",
	}
	for _, c := range candidates {
		if data, err := os.ReadFile(c); err == nil {
			s := strings.TrimSpace(string(data))
			if s != "" {
				return s
			}
		}
	}
	return "KOREADER001"
}

func unbindAllGadgets(logf func(string, ...any)) {
	entries, err := os.ReadDir(gadgetBase)
	if err != nil {
		return
	}
	unbound := false
	for _, e := range entries {
		udcPath := filepath.Join(gadgetBase, e.Name(), "UDC")
		data, err := os.ReadFile(udcPath)
		if err != nil {
			continue
		}
		if strings.TrimSpace(string(data)) != "" {
			logf("unbinding existing UDC on gadget %s (%s)", e.Name(), strings.TrimSpace(string(data)))
			_ = os.WriteFile(udcPath, []byte("\n"), 0644)
			unbound = true
		}
	}
	if unbound {
		time.Sleep(250 * time.Millisecond)
	}
}

func teardownGadget(st *gadgetState, logf func(string, ...any)) {
	if st != nil && st.FFS != nil {
		st.FFS.Close()
		st.FFS = nil
	}
	if st != nil && st.Ifname != "" {
		_ = exec.Command("ifconfig", st.Ifname, "down").Run()
		removeIptablesIf(st.Ifname)
	}

	udcPath := filepath.Join(gadgetDir, "UDC")
	if data, err := os.ReadFile(udcPath); err == nil && strings.TrimSpace(string(data)) != "" {
		_ = os.WriteFile(udcPath, []byte("\n"), 0644)
		time.Sleep(150 * time.Millisecond)
	}

	_ = unmountFunctionFS(ffsMountPoint)

	cfgDir := filepath.Join(gadgetDir, "configs", "c.1")
	if entries, err := os.ReadDir(cfgDir); err == nil {
		for _, e := range entries {
			p := filepath.Join(cfgDir, e.Name())
			if fi, lerr := os.Lstat(p); lerr == nil && (fi.Mode()&os.ModeSymlink != 0) {
				_ = os.Remove(p)
			}
		}
	}
	_ = os.Remove(filepath.Join(cfgDir, "strings", "0x409"))
	_ = os.Remove(cfgDir)

	fnBase := filepath.Join(gadgetDir, "functions")
	if entries, err := os.ReadDir(fnBase); err == nil {
		for _, e := range entries {
			_ = os.Remove(filepath.Join(fnBase, e.Name()))
		}
	}
	_ = os.Remove(filepath.Join(gadgetDir, "strings", "0x409"))
	if err := os.Remove(gadgetDir); err != nil && !os.IsNotExist(err) {
		logf("teardownGadget rmdir %s: %v", gadgetDir, err)
	}
}

func initBaseGadget(pidHex, productStr, configName string) error {
	for _, dir := range []string{
		gadgetDir,
		filepath.Join(gadgetDir, "strings", "0x409"),
		filepath.Join(gadgetDir, "configs", "c.1"),
		filepath.Join(gadgetDir, "configs", "c.1", "strings", "0x409"),
	} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}

	writes := map[string]string{
		filepath.Join(gadgetDir, "idVendor"):                                       "0x1949\n",
		filepath.Join(gadgetDir, "idProduct"):                                      pidHex + "\n",
		filepath.Join(gadgetDir, "bcdUSB"):                                         "0x0200\n",
		filepath.Join(gadgetDir, "bcdDevice"):                                      "0x0100\n",
		filepath.Join(gadgetDir, "bDeviceClass"):                                   "0x00\n",
		filepath.Join(gadgetDir, "bDeviceSubClass"):                                "0x00\n",
		filepath.Join(gadgetDir, "bDeviceProtocol"):                                "0x00\n",
		filepath.Join(gadgetDir, "strings", "0x409", "serialnumber"):               readKindleSerial() + "\n",
		filepath.Join(gadgetDir, "strings", "0x409", "manufacturer"):               "Amazon\n",
		filepath.Join(gadgetDir, "strings", "0x409", "product"):                    productStr + "\n",
		filepath.Join(gadgetDir, "configs", "c.1", "MaxPower"):                     "500\n",
		filepath.Join(gadgetDir, "configs", "c.1", "strings", "0x409", "configuration"): configName + "\n",
	}
	for p, val := range writes {
		if err := os.WriteFile(p, []byte(val), 0644); err != nil {
			return fmt.Errorf("write %s: %w", p, err)
		}
	}
	return nil
}

func configureNetIf(ifname string, logf func(string, ...any)) error {
	if err := exec.Command("ifconfig", ifname, "192.168.15.1", "netmask", "255.255.255.0", "up").Run(); err == nil {
		return nil
	}
	_ = exec.Command("ip", "addr", "replace", "192.168.15.1/24", "dev", ifname).Run()
	if err := exec.Command("ip", "link", "set", ifname, "up").Run(); err != nil {
		logf("configureNetIf(%s) failed: %v", ifname, err)
		return err
	}
	return nil
}

func ensureNetIfConfigured(ifname string, logf func(string, ...any)) {
	iface, err := net.InterfaceByName(ifname)
	if err != nil {
		return
	}
	hasIP := false
	if addrs, aerr := iface.Addrs(); aerr == nil {
		for _, a := range addrs {
			if strings.HasPrefix(a.String(), "192.168.15.1/") {
				hasIP = true
				break
			}
		}
	}
	if iface.Flags&net.FlagUp == 0 || !hasIP {
		_ = configureNetIf(ifname, logf)
	}
}

func installIptablesIf(ifname string) {
	removeIptablesIf(ifname)
	_ = exec.Command("iptables", "-I", "INPUT", "1", "-i", ifname, "-j", "ACCEPT").Run()
	_ = exec.Command("iptables", "-I", "OUTPUT", "1", "-o", ifname, "-j", "ACCEPT").Run()
}

func removeIptablesIf(ifname string) {
	if ifname == "" {
		return
	}
	_ = exec.Command("iptables", "-D", "INPUT", "-i", ifname, "-j", "ACCEPT").Run()
	_ = exec.Command("iptables", "-D", "OUTPUT", "-o", ifname, "-j", "ACCEPT").Run()
}

func startUSBGadget(ctx context.Context, logf func(string, ...any)) (*gadgetState, error) {
	if err := ensureConfigFS(logf); err != nil {
		return nil, err
	}
	udcName, err := findUDCName()
	if err != nil {
		return nil, err
	}

	unbindAllGadgets(logf)
	teardownGadget(nil, logf)

	// Mode 1: Try native macOS USB Ethernet (CDC-NCM first, then CDC-ECM).
	for _, cand := range []struct {
		mode   string
		fnName string
	}{
		{"ncm", "ncm.usb0"},
		{"ecm", "ecm.usb0"},
	} {
		teardownGadget(nil, logf)
		if err := initBaseGadget("0x9983", "Kindle KOReader USBNet", "USBNet"); err != nil {
			logf("initBaseGadget(%s) err: %v", cand.mode, err)
			continue
		}
		fnDir := filepath.Join(gadgetDir, "functions", cand.fnName)
		if err := os.MkdirAll(fnDir, 0755); err != nil {
			logf("gadget function %s unavailable: %v", cand.fnName, err)
			continue
		}
		_ = os.WriteFile(filepath.Join(fnDir, "host_addr"), []byte("02:19:49:6b:68:01\n"), 0644)
		_ = os.WriteFile(filepath.Join(fnDir, "dev_addr"), []byte("02:19:49:6b:68:02\n"), 0644)

		linkPath := filepath.Join(gadgetDir, "configs", "c.1", cand.fnName)
		if err := os.Symlink(fnDir, linkPath); err != nil {
			logf("symlink %s failed: %v", cand.fnName, err)
			continue
		}
		if err := os.WriteFile(filepath.Join(gadgetDir, "UDC"), []byte(udcName+"\n"), 0644); err != nil {
			logf("UDC bind %s failed for %s: %v", udcName, cand.fnName, err)
			continue
		}

		ifname := "usb0"
		if rawIf, rerr := os.ReadFile(filepath.Join(fnDir, "ifname")); rerr == nil {
			if trimmed := strings.TrimSpace(string(rawIf)); trimmed != "" {
				ifname = trimmed
			}
		}
		_ = configureNetIf(ifname, logf)
		installIptablesIf(ifname)
		startDHCPServer(ctx, ifname, logf)

		logf("activated USB %s mode on %s (ifname=%s ip=192.168.15.1)", cand.mode, udcName, ifname)
		return &gadgetState{
			Mode:   cand.mode,
			Ifname: ifname,
			IP:     "192.168.15.1",
			VID:    "1949",
			PID:    "9983",
			UDC:    udcName,
		}, nil
	}

	// Mode 2: Guaranteed Fallback via FunctionFS Bulk TCP multiplexer.
	logf("NCM/ECM unavailable; falling back to FunctionFS (ffs.usbdbg)")
	teardownGadget(nil, logf)
	if err := initBaseGadget("0x9982", "Kindle KOReader USBDebug FFS", "USBDebug"); err != nil {
		return nil, err
	}
	sess, err := startFunctionFSSession(ctx, gadgetDir, udcName, logf)
	if err != nil {
		teardownGadget(nil, logf)
		return nil, err
	}
	logf("activated USB ffs mode on %s (1949:9982 -> 127.0.0.1:2222)", udcName)
	return &gadgetState{
		Mode: "ffs",
		IP:   "127.0.0.1",
		VID:  "1949",
		PID:  "9982",
		UDC:  udcName,
		FFS:  sess,
	}, nil
}

// Keep unused import check satisfied if bytes needed later.
var _ = bytes.Equal
