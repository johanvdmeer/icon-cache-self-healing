//go:build !windows

// syscall_other.go
// Stub for non-Windows platforms (allows development/testing on Linux/macOS).

package main

import "syscall"

func sysProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{}
}
