//go:build linux

package main

import (
	"fmt"
	"os"
	"syscall"
)

func mountFunctionFS(mountPoint string) error {
	if err := os.MkdirAll(mountPoint, 0755); err != nil {
		return err
	}
	if err := syscall.Mount("usbdbg", mountPoint, "functionfs", 0, ""); err != nil {
		return fmt.Errorf("mount functionfs %s: %w", mountPoint, err)
	}
	return nil
}

func unmountFunctionFS(mountPoint string) error {
	if err := syscall.Unmount(mountPoint, 0); err != nil {
		// MNT_DETACH (2) handles busy mountpoints during abrupt teardown.
		return syscall.Unmount(mountPoint, 2)
	}
	return nil
}

func bindSocketToDevice(fd uintptr, ifname string) error {
	if err := syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1); err != nil {
		return fmt.Errorf("SO_REUSEADDR: %w", err)
	}
	if err := syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_BROADCAST, 1); err != nil {
		return fmt.Errorf("SO_BROADCAST: %w", err)
	}
	if ifname != "" {
		if err := syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, ifname); err != nil {
			return fmt.Errorf("SO_BINDTODEVICE(%s): %w", ifname, err)
		}
	}
	return nil
}
