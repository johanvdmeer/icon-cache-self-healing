// icon-cache-watchdog — Self-healing Windows icon cache daemon
// Compiled as a Windows GUI subsystem binary: zero console window, ever.
//
// Architecture:
//   Layer A: Event-driven repair via Task Scheduler (handled in Register-Tasks.ps1)
//   Layer B: FileSystemWatcher — detects cache size growth
//   Layer C: Logon health check — runs once at startup
//   Layer D: Periodic health check — runs every 45 minutes
//
// Naming Policy: naming-conventions-policy-v3.2.0
// Build:         go build -ldflags="-H windowsgui" -o bin/icon-cache-watchdog.exe ./daemon
// Log output:    logs/Watchdog.log, logs/IconCacheHealth.log

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// CONFIGURATION
// ---------------------------------------------------------------------------

const (
	sizeLimitMB        = 32            // Repair if cache exceeds this
	cooldownMinutes    = 30            // Min minutes between repairs
	healthCheckEvery   = 45 * time.Minute
	heartbeatEvery     = 6 * time.Hour
	recentWriteMinutes = 15            // H2: suspicious external write window
	minHealthyFiles    = 5             // H3: minimum expected cache files
	staleAgeDays       = 30            // H4: preemptive refresh threshold
	idxMinBytes        = 100           // H1: index file minimum healthy size
)

// ---------------------------------------------------------------------------
// STATE
// ---------------------------------------------------------------------------

type daemon struct {
	cacheDir     string
	repairScript string
	logDir       string
	watchLog     string
	healthLog    string
	mu           sync.Mutex
	lastRepair   time.Time
}

// ---------------------------------------------------------------------------
// LOGGING
// ---------------------------------------------------------------------------

func (d *daemon) log(file, level, msg string) {
	os.MkdirAll(d.logDir, 0755)
	f, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	ts := time.Now().Format("2006-01-02 15:04:05")
	fmt.Fprintf(f, "[%s][%s] %s\n", ts, level, msg)
}

func (d *daemon) watchLog_(level, msg string) { d.log(d.watchLog, level, msg) }
func (d *daemon) healthLog_(level, msg string) { d.log(d.healthLog, level, msg) }

// ---------------------------------------------------------------------------
// CACHE HELPERS
// ---------------------------------------------------------------------------

func (d *daemon) getCacheFiles() []os.FileInfo {
	entries, err := os.ReadDir(d.cacheDir)
	if err != nil {
		return nil
	}
	var files []os.FileInfo
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), "iconcache_") && strings.HasSuffix(e.Name(), ".db") {
			if info, err := e.Info(); err == nil {
				files = append(files, info)
			}
		}
	}
	return files
}

func (d *daemon) getCacheSizeMB() float64 {
	files := d.getCacheFiles()
	var total int64
	for _, f := range files {
		total += f.Size()
	}
	return float64(total) / (1024 * 1024)
}

// ---------------------------------------------------------------------------
// REPAIR
// ---------------------------------------------------------------------------

func (d *daemon) triggerRepair(reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if time.Since(d.lastRepair).Minutes() < float64(cooldownMinutes) {
		remaining := float64(cooldownMinutes) - time.Since(d.lastRepair).Minutes()
		d.watchLog_("WARN", fmt.Sprintf("Cooldown active (%.0f min remaining). Skipping repair. Reason was: %s", remaining, reason))
		return
	}

	d.watchLog_("TRIGGER", fmt.Sprintf("Repair triggered: %s", reason))

	// Launch repair script silently via PowerShell
	// pwsh.exe is invisible here because WE are the GUI-subsystem process.
	// Child processes inherit our windowless context.
	pwsh := findPowerShell()
	cmd := exec.Command(pwsh,
		"-WindowStyle", "Hidden",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", d.repairScript,
	)
	cmd.SysProcAttr = sysProcAttr() // platform-specific: CREATE_NO_WINDOW
	if err := cmd.Start(); err != nil {
		d.watchLog_("ERROR", fmt.Sprintf("Failed to launch repair script: %v", err))
		return
	}

	d.lastRepair = time.Now()
	d.watchLog_("INFO", "Repair script launched successfully.")
}

// ---------------------------------------------------------------------------
// LAYER B: FileSystem Polling
// Go's fsnotify would be ideal but adds a dependency.
// We use a lightweight 30-second poll — still far more responsive than
// the old 5-minute Wait-Event loop, and zero external dependencies.
// ---------------------------------------------------------------------------

func (d *daemon) runWatchdog() {
	d.watchLog_("INFO", "=== icon-cache-watchdog started ===")
	d.watchLog_("INFO", fmt.Sprintf("Watching: %s", d.cacheDir))
	d.watchLog_("INFO", fmt.Sprintf("Threshold: %d MB | Cooldown: %d min", sizeLimitMB, cooldownMinutes))
	d.watchLog_("INFO", fmt.Sprintf("Repair script: %s", d.repairScript))
	d.watchLog_("INFO", "Mechanism: polling every 30 seconds (pure Go, no dependencies)")

	sizeMB := d.getCacheSizeMB()
	d.watchLog_("INFO", fmt.Sprintf("Cache size at startup: %.2f MB", sizeMB))

	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	heartbeat := time.NewTicker(heartbeatEvery)
	defer heartbeat.Stop()

	for {
		select {
		case <-ticker.C:
			sizeMB := d.getCacheSizeMB()
			if sizeMB > float64(sizeLimitMB) {
				d.watchLog_("TRIGGER", fmt.Sprintf("Cache is %.2f MB > %d MB threshold.", sizeMB, sizeLimitMB))
				d.triggerRepair(fmt.Sprintf("size %.2f MB exceeds %d MB limit", sizeMB, sizeLimitMB))
			}

		case <-heartbeat.C:
			sizeMB := d.getCacheSizeMB()
			d.watchLog_("HEARTBEAT", fmt.Sprintf("Watchdog alive. Cache: %.2f MB (threshold: %d MB)", sizeMB, sizeLimitMB))
		}
	}
}

// ---------------------------------------------------------------------------
// LAYER C+D: Health Check Heuristics
// ---------------------------------------------------------------------------

func (d *daemon) runHealthChecks() {
	// Layer C: run immediately at startup
	d.healthLog_("INFO", "--- Health check running (startup) ---")
	d.checkHealth()

	// Layer D: repeat every 45 minutes
	ticker := time.NewTicker(healthCheckEvery)
	defer ticker.Stop()

	for range ticker.C {
		d.healthLog_("INFO", fmt.Sprintf("--- Health check running (periodic, every %.0f min) ---", healthCheckEvery.Minutes()))
		d.checkHealth()
	}
}

func (d *daemon) checkHealth() {
	h1 := d.checkH1Index()
	h2 := d.checkH2RecentWrite()
	h3 := d.checkH3FileCount()
	h4 := d.checkH4Staleness()

	if h1 && h2 && h3 && h4 {
		d.healthLog_("PASS", "=== ALL HEURISTICS PASSED. Cache is healthy. ===")
		return
	}

	d.healthLog_("REPAIR", "=== HEURISTIC FAILURE. Triggering repair... ===")
	d.triggerRepair("health check heuristic failure")
}

// H1: Index file present and non-empty
func (d *daemon) checkH1Index() bool {
	idxPath := filepath.Join(d.cacheDir, "iconcache_idx.db")
	info, err := os.Stat(idxPath)
	if err != nil {
		d.healthLog_("WARN", "H1 FAIL: iconcache_idx.db is missing.")
		return false
	}
	if info.Size() < idxMinBytes {
		d.healthLog_("WARN", fmt.Sprintf("H1 FAIL: iconcache_idx.db is %d bytes (expected >%d). Index corrupt.", info.Size(), idxMinBytes))
		return false
	}
	d.healthLog_("PASS", fmt.Sprintf("H1 PASS: iconcache_idx.db present and %.1f KB.", float64(info.Size())/1024))
	return true
}

// H2: Main cache not recently written while Explorer was not running
func (d *daemon) checkH2RecentWrite() bool {
	mainCache := filepath.Join(d.cacheDir, "iconcache_256.db")
	info, err := os.Stat(mainCache)
	if err != nil {
		d.healthLog_("PASS", "H2 PASS: iconcache_256.db not present (will be created on next Explorer start).")
		return true
	}

	minutesAgo := time.Since(info.ModTime()).Minutes()
	if minutesAgo < float64(recentWriteMinutes) {
		if !isExplorerRunning() {
			d.healthLog_("WARN", fmt.Sprintf("H2 FAIL: iconcache_256.db written %.1f min ago while Explorer was NOT running.", minutesAgo))
			return false
		}
		d.healthLog_("PASS", "H2 PASS: Recently modified but Explorer was running (normal rebuild).")
	} else {
		d.healthLog_("PASS", fmt.Sprintf("H2 PASS: Last modified %.0f min ago (outside suspicious window).", minutesAgo))
	}
	return true
}

// H3: Enough cache files exist while Explorer is running
func (d *daemon) checkH3FileCount() bool {
	files := d.getCacheFiles()
	count := len(files)
	if isExplorerRunning() && count < minHealthyFiles {
		d.healthLog_("WARN", fmt.Sprintf("H3 FAIL: Only %d cache files while Explorer is running (expected >=%d).", count, minHealthyFiles))
		return false
	}
	d.healthLog_("PASS", fmt.Sprintf("H3 PASS: %d cache files present.", count))
	return true
}

// H4: Cache is not stale
func (d *daemon) checkH4Staleness() bool {
	files := d.getCacheFiles()
	if len(files) == 0 {
		return true
	}
	var newest time.Time
	for _, f := range files {
		if f.ModTime().After(newest) {
			newest = f.ModTime()
		}
	}
	daysOld := time.Since(newest).Hours() / 24
	if daysOld > float64(staleAgeDays) {
		d.healthLog_("WARN", fmt.Sprintf("H4 FAIL: Cache last updated %.0f days ago. Preemptive refresh.", daysOld))
		return false
	}
	d.healthLog_("PASS", fmt.Sprintf("H4 PASS: Cache last updated %.1f days ago.", daysOld))
	return true
}

// ---------------------------------------------------------------------------
// HELPERS
// ---------------------------------------------------------------------------

func findPowerShell() string {
	pwsh7 := filepath.Join(os.Getenv("ProgramFiles"), "PowerShell", "7", "pwsh.exe")
	if _, err := os.Stat(pwsh7); err == nil {
		return pwsh7
	}
	return "powershell.exe"
}

func isExplorerRunning() bool {
	// Check if explorer.exe process exists
	if runtime.GOOS != "windows" {
		return true // assume running in non-Windows environments
	}
	cmd := exec.Command("tasklist", "/FI", "IMAGENAME eq explorer.exe", "/NH")
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToLower(string(out)), "explorer.exe")
}

// ---------------------------------------------------------------------------
// ENTRY POINT
// ---------------------------------------------------------------------------

func main() {
	// Resolve paths relative to executable location
	exeDir, err := filepath.Abs(filepath.Dir(os.Args[0]))
	if err != nil {
		exeDir = "."
	}

	// Navigate from bin/ up to project root
	rootDir := filepath.Dir(exeDir)

	// Support running from project root directly (during development)
	if _, err := os.Stat(filepath.Join(exeDir, "scripts")); err == nil {
		rootDir = exeDir
	}

	localAppData := os.Getenv("LOCALAPPDATA")

	d := &daemon{
		cacheDir:     filepath.Join(localAppData, "Microsoft", "Windows", "Explorer"),
		repairScript: filepath.Join(rootDir, "scripts", "Repair-IconCache.ps1"),
		logDir:       filepath.Join(rootDir, "logs"),
		watchLog:     filepath.Join(rootDir, "logs", "Watchdog.log"),
		healthLog:    filepath.Join(rootDir, "logs", "IconCacheHealth.log"),
		lastRepair:   time.Time{},
	}

	d.watchLog_("INFO", fmt.Sprintf("Daemon starting. Root: %s", rootDir))
	d.watchLog_("INFO", fmt.Sprintf("Cache dir: %s", d.cacheDir))

	// Run Layer C+D health checks in background goroutine
	go d.runHealthChecks()

	// Run Layer B watchdog in main goroutine (blocks forever)
	d.runWatchdog()
}
