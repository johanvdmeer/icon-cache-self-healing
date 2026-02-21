// syscall_windows.go
// Platform-specific process creation flags for Windows.
// CREATE_NO_WINDOW (0x08000000) prevents any console window from appearing
// when this process spawns child processes (PowerShell repair scripts).
// This file is only compiled on Windows (build tag enforced by filename).

package main

import "syscall"

func sysProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		CreationFlags: 0x08000000, // CREATE_NO_WINDOW
		HideWindow:    true,
	}
}
