//go:build !linux

package main

import "fmt"

func mountFunctionFS(mountPoint string) error {
	return fmt.Errorf("functionfs unsupported on non-linux")
}

func unmountFunctionFS(mountPoint string) error {
	return nil
}

func bindSocketToDevice(fd uintptr, ifname string) error {
	return nil
}
