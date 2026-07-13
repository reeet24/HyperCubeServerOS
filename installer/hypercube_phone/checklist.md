# ✅ HyperCube Kernel Development Checklist

Track progress of your HyperCube base kernel to support drivers and programs.

---

## 📦 Core System

- [x] Implement standardized `Context` schema
- [x] Enforce access control via `Context` (permissions, UID, PID)
- [x] Create system-level function signature rules (e.g., `fn(context, ...)`)
- [x] Provide default root context with full privileges

---

## 🧠 Process & Task Management

- [x] Coroutine-based multitasking (`yield`, `sleep`, `tick`)
- [x] Process metadata tracking (PID, name, status, parent)
- [x] Process registry / table for lookup
- [x] Daemon support (headless / background tasks)
- [x] Process control API (`kill`, `suspend`, `resume`)
- [x] Init system / startup task runner

---

## 📁 Filesystem Abstraction

- [x] VFS interface (`fs.open`, `fs.read`, `fs.write`, etc.)
- [x] Directory operations (`fs.list`, `fs.makeDir`, `fs.remove`)
- [x] File handle object with `read`, `write`, `seek`, `close`
- [x] Support for mountable backends (e.g., RAMdisk)
- [x] Sandbox-aware path resolution

---

## 🧩 Module & Driver Loader

- [x] `load_module(path)` for kernel modules
- [x] Driver interface standard (`init(context)`, `shutdown()`)
- [ ] Dependency/version check system
- [x] Hot-reloadable drivers/modules
- [x] Driver auto-loader (via `drivers/` folder)

---

## 📡 IPC / Signal System

- [x] Implement `SignalBus` or `EventBus` API
- [x] Allow emit/listen pattern for system events
- [x] Support namespaced signals or tags
- [x] Built-in system signals (e.g., `on_tick`, `on_shutdown`)

---

## 🔐 Syscall Interface

- [x] Define syscall routing map
- [x] Implement `sys.call(name, ...)` interface
- [x] Expose controlled set of kernel APIs
- [x] Validate and filter arguments via context

---

## 🖥️ Shell & Program Runner

- [x] Base shell framework (`execute` command)
- [ ] Background job support (`&`, job control)
- [x] Standardized program metadata format
- [x] Script sandbox with safe globals
- [x] Program folder scanner (`programs/`)

---

## 📚 Standard Library for Programs

- [x] Safe versions of `os`, `fs`, `net`, etc.
- [x] No access to dangerous APIs (`io`, `debug`, `os.shutdown`)
- [x] Per-process environment isolation
- [x] Auto-inject safe API wrapper to program context

---

## 🪵 Logging & Debugging

- [x] `logger.log(level, msg, context)` API
- [x] Log levels: `INFO`, `WARN`, `ERROR`, `DEBUG`
- [x] Persistent log storage (`/logs/kernel.log`)
- [ ] Kernel panic / fatal error handler
- [ ] Live log viewer tool (optional)

---

## ⚙️ Optional Enhancements

- [ ] Config manager (`/etc/config.lua`)
- [ ] System info utility (`sysinfo`, `uptime`, etc.)
- [ ] Test runner for kernel modules
- [ ] Crash recovery or reboot fallback
- [ ] Kernel watchdog daemon
- [ ] Kernel metrics/stats tracking

---

## 🧪 Ready-to-Build Drivers

Once core is ready, begin with:

- [x] `screen` or `gpu` output driver
- [ ] `clock` or `time` daemon
- [ ] `filesystem` (e.g., RAMdisk or bootfs)
- [x] `network` stub or fake device
