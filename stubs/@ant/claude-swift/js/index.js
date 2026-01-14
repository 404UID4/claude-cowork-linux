/**
 * Linux stub for @ant/claude-swift
 *
 * This module replaces the native Swift addon that uses Apple's Virtualization
 * Framework on macOS. On Linux, we don't need a VM - we run the Claude Code
 * binary directly on the host system.
 *
 * Architecture:
 *   Claude Desktop (Electron) -> This Stub -> child_process.spawn() -> Claude Binary
 *
 * Key insight from reverse engineering:
 *   - The app imports this module and calls Si() which returns `module.default.vm`
 *   - Therefore, all VM methods must be on `this.vm`, not on the class itself
 *   - The app calls vm.setEventCallbacks() to register stdout/stderr/exit handlers
 *   - Then vm.spawn() to launch the Claude Code binary
 *
 * Path translations performed:
 *   - /usr/local/bin/claude -> ~/.config/Claude/claude-code-vm/2.1.5/claude
 *   - /sessions/... -> ~/.local/share/claude-cowork/sessions/...
 *
 * Security hardening applied:
 *   - Command injection prevention (execFile instead of exec)
 *   - Path traversal protection
 *   - Environment variable filtering
 *   - Secure file permissions
 *
 * Based on reverse engineering of swift_addon.node via pyghidra-lite
 */
console.log('[claude-swift-stub] LOADING MODULE - this confirms our stub is being used');
const EventEmitter = require("events");
const { spawn: nodeSpawn, spawnSync: nodeSpawnSync, execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

// SECURITY: Log to user-writable location with restricted permissions
const LOG_DIR = path.join(os.homedir(), '.local/share/claude-cowork/logs');
const TRACE_FILE = path.join(LOG_DIR, 'claude-swift-trace.log');

// Ensure log directory exists with secure permissions
try {
  fs.mkdirSync(LOG_DIR, { recursive: true, mode: 0o700 });
} catch (e) {}

const TRACE_IO = process.env.CLAUDE_COWORK_TRACE_IO === '1';

function redactForLogs(input) {
  let text = String(input);

  // Common header / token formats
  text = text.replace(/(Authorization:\s*Bearer)\s+[^\s]+/gi, '$1 [REDACTED]');
  text = text.replace(/(Bearer)\s+[A-Za-z0-9._-]+/g, '$1 [REDACTED]');

  // JSON-style secrets
  text = text.replace(/("authorization"\s*:\s*")[^"]+(")/gi, '$1[REDACTED]$2');
  text = text.replace(/("api[_-]?key"\s*:\s*")[^"]+(")/gi, '$1[REDACTED]$2');
  text = text.replace(/("access[_-]?token"\s*:\s*")[^"]+(")/gi, '$1[REDACTED]$2');
  text = text.replace(/("refresh[_-]?token"\s*:\s*")[^"]+(")/gi, '$1[REDACTED]$2');

  // Env var leakage
  text = text.replace(/(ANTHROPIC_API_KEY=)[^\s]+/g, '$1[REDACTED]');

  // Cookies
  text = text.replace(/(cookie:\s*)[^\n\r]+/gi, '$1[REDACTED]');

  return text;
}

function trace(msg) {
  const ts = new Date().toISOString();
  const safeMsg = redactForLogs(msg);
  const line = `[${ts}] ${safeMsg}\n`;
  console.log('[TRACE] ' + safeMsg);
  try {
    // SECURITY: Append with restrictive permissions
    fs.appendFileSync(TRACE_FILE, line, { mode: 0o600 });
  } catch(e) {}
}
trace("=== MODULE LOADING ===");
trace("Trace IO logging: " + (TRACE_IO ? "enabled (CLAUDE_COWORK_TRACE_IO=1)" : "disabled"));

// SECURITY: Allowlist of environment variables to pass to spawned process
const ENV_ALLOWLIST = [
  'PATH', 'HOME', 'USER', 'SHELL', 'TERM', 'LANG', 'LC_ALL', 'LC_CTYPE',
  'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME',
  'DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS',
  'NODE_ENV', 'ELECTRON_RUN_AS_NODE',
  // Claude-specific
  'ANTHROPIC_API_KEY', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX'
];

function filterEnv(baseEnv, additionalEnv) {
  const filtered = {};
  for (const key of ENV_ALLOWLIST) {
    if (baseEnv[key] !== undefined) {
      filtered[key] = baseEnv[key];
    }
  }
  // Additional env vars from the app are trusted (come from Claude Desktop)
  if (additionalEnv) {
    Object.assign(filtered, additionalEnv);
  }
  return filtered;
}

// SECURITY: Validate path doesn't escape intended directory
function isPathSafe(basePath, targetPath) {
  const resolved = path.resolve(basePath, targetPath);
  return resolved.startsWith(path.resolve(basePath) + path.sep) || resolved === path.resolve(basePath);
}

// Sessions directory in user space (not /sessions)
const SESSIONS_BASE = path.join(os.homedir(), '.local/share/claude-cowork/sessions');

class SwiftAddonStub extends EventEmitter {
  constructor() {
    super();
    trace('Constructor START');
    console.log('[claude-swift-stub] Constructor called');
    this._eventListener = null;
    this._guestConnected = false;
    this._processes = new Map();
    this._processIdCounter = 0;

    // Event callbacks for VM processes
    this._onStdout = null;
    this._onStderr = null;
    this._onExit = null;
    this._onError = null;
    this._onNetworkStatus = null;

    // Events system - native.events.setListener()
    this.events = {
      setListener: (callback) => {
        this._eventListener = callback;
        console.log('[claude-swift] Event listener registered');
      }
    };

    // Quick Access / Quick Entry UI
    this.quickAccess = {
      show: () => {
        console.log('[claude-swift] quickAccess.show()');
        this._emit('quickAccessShown');
      },
      hide: () => {
        console.log('[claude-swift] quickAccess.hide()');
        this._emit('quickAccessHidden');
      },
      isVisible: () => false,
      submit: (data) => {
        console.log('[claude-swift] quickAccess.submit()', data);
      }
    };

    // Notifications
    this.notifications = {
      requestAuth: () => {
        console.log('[claude-swift] notifications.requestAuth()');
        return Promise.resolve(true);
      },
      getAuthStatus: () => {
        return 'authorized';
      },
      show: (options) => {
        console.log('[claude-swift] notifications.show()', options && options.title);
        try {
          const title = String((options && options.title) || 'Claude').substring(0, 200);
          const body = String((options && options.body) || '').substring(0, 1000);
          // SECURITY: Use execFileSync with argument array to prevent command injection
          execFileSync('notify-send', [title, body], { timeout: 5000, stdio: 'ignore' });
        } catch (e) {
          // Notification failed - not critical
        }
        return Promise.resolve({ id: Date.now().toString() });
      },
      close: (id) => {
        console.log('[claude-swift] notifications.close()', id);
      }
    };

    // Desktop integration
    this.desktop = {
      captureScreenshot: (args) => {
        console.log('[claude-swift] desktop.captureScreenshot()', args);
        return Promise.resolve(null);
      },
      captureWindowScreenshot: (windowId) => {
        console.log('[claude-swift] desktop.captureWindowScreenshot()', windowId);
        return Promise.resolve(null);
      },
      getSessionId: () => {
        return 'linux-session-' + Date.now();
      },
      // Get list of open documents (Linux implementation)
      getOpenDocuments: () => {
        console.log('[claude-swift] desktop.getOpenDocuments()');
        // On Linux, we can check recent files or return empty
        // Could integrate with GTK recent files or track opened files
        return Promise.resolve([]);
      },
      // Get list of open windows
      getOpenWindows: () => {
        console.log('[claude-swift] desktop.getOpenWindows()');
        try {
          // Try wmctrl first, fall back to empty
          const { execFileSync } = require('child_process');
          const output = execFileSync('wmctrl', ['-l'], { encoding: 'utf-8', timeout: 2000 });
          const windows = output.trim().split('\n').filter(Boolean).map(line => {
            const parts = line.split(/\s+/);
            return {
              id: parts[0],
              desktop: parts[1],
              title: parts.slice(3).join(' ')
            };
          });
          return Promise.resolve(windows);
        } catch (e) {
          return Promise.resolve([]);
        }
      },
      // Open file with default application
      openFile: (filePath) => {
        console.log('[claude-swift] desktop.openFile()', filePath);
        try {
          const { execFile } = require('child_process');
          execFile('xdg-open', [filePath], (err) => {
            if (err) console.error('[claude-swift] openFile error:', err.message);
          });
          return Promise.resolve(true);
        } catch (e) {
          return Promise.resolve(false);
        }
      },
      // Reveal file in file manager
      revealFile: (filePath) => {
        console.log('[claude-swift] desktop.revealFile()', filePath);
        try {
          const { execFile } = require('child_process');
          const dir = path.dirname(filePath);
          // Try nautilus first (GNOME), fall back to xdg-open
          execFile('nautilus', ['--select', filePath], (err) => {
            if (err) {
              // Fall back to opening the directory
              execFile('xdg-open', [dir], () => {});
            }
          });
          return Promise.resolve(true);
        } catch (e) {
          return Promise.resolve(false);
        }
      },
      // Preview file (Quick Look equivalent)
      previewFile: (filePath) => {
        console.log('[claude-swift] desktop.previewFile()', filePath);
        try {
          const { execFile } = require('child_process');
          // Try gnome-sushi (GNOME Quick Look), fall back to xdg-open
          execFile('gnome-sushi', [filePath], (err) => {
            if (err) {
              execFile('xdg-open', [filePath], () => {});
            }
          });
          return Promise.resolve(true);
        } catch (e) {
          return Promise.resolve(false);
        }
      }
    };

    // File system operations
    this.files = {
      // Read file contents
      read: (filePath) => {
        console.log('[claude-swift] files.read()', filePath);
        try {
          const content = fs.readFileSync(filePath, 'utf-8');
          return Promise.resolve(content);
        } catch (e) {
          return Promise.reject(e);
        }
      },
      // Write file contents
      write: (filePath, content) => {
        console.log('[claude-swift] files.write()', filePath);
        try {
          fs.writeFileSync(filePath, content, 'utf-8');
          return Promise.resolve(true);
        } catch (e) {
          return Promise.reject(e);
        }
      },
      // Check if file exists
      exists: (filePath) => {
        return Promise.resolve(fs.existsSync(filePath));
      },
      // Get file stats
      stat: (filePath) => {
        console.log('[claude-swift] files.stat()', filePath);
        try {
          const stats = fs.statSync(filePath);
          return Promise.resolve({
            size: stats.size,
            isFile: stats.isFile(),
            isDirectory: stats.isDirectory(),
            created: stats.birthtime,
            modified: stats.mtime,
            accessed: stats.atime
          });
        } catch (e) {
          return Promise.reject(e);
        }
      },
      // List directory contents
      list: (dirPath) => {
        console.log('[claude-swift] files.list()', dirPath);
        try {
          const entries = fs.readdirSync(dirPath, { withFileTypes: true });
          return Promise.resolve(entries.map(e => ({
            name: e.name,
            isFile: e.isFile(),
            isDirectory: e.isDirectory(),
            path: path.join(dirPath, e.name)
          })));
        } catch (e) {
          return Promise.reject(e);
        }
      },
      // Watch file for changes
      watch: (filePath, callback) => {
        console.log('[claude-swift] files.watch()', filePath);
        try {
          const watcher = fs.watch(filePath, (eventType, filename) => {
            callback({ type: eventType, filename });
          });
          return { close: () => watcher.close() };
        } catch (e) {
          return { close: () => {} };
        }
      }
    };

    // API object (general purpose)
    this.api = {};

    // Midnight Owl (scheduling/time-based features)
    this.midnightOwl = {
      isEnabled: () => false,
      enable: () => {},
      disable: () => {},
    };

    // VM Management (nested object)
    // CRITICAL: The app accesses methods via module.default.vm, so all methods must be here
    const self = this;

    /**
     * VM object - This is the main interface the app uses
     * The app calls Si() which returns module.default.vm
     */
    this.vm = {
      isSupported: () => true,
      isGuestConnected: () => self._guestConnected,
      getRunningStatus: () => ({
        running: self._guestConnected,
        connected: self._guestConnected
      }),

      setEventCallbacks: (onStdout, onStderr, onExit, onError, onNetworkStatus) => {
        trace('vm.setEventCallbacks() CALLED');
        console.log('[claude-swift] vm.setEventCallbacks() called - REGISTERING CALLBACKS');
        self._onStdout = onStdout;
        self._onStderr = onStderr;
        self._onExit = onExit;
        self._onError = onError;
        self._onNetworkStatus = onNetworkStatus;
        if (self._onNetworkStatus) {
          self._onNetworkStatus('connected');
        }
      },

      startVM: async (bundlePath, memoryGB) => {
        trace('vm.startVM() bundlePath=' + bundlePath + ' memoryGB=' + memoryGB);
        console.log('[claude-swift] vm.startVM() bundlePath=' + bundlePath + ' memoryGB=' + memoryGB);
        self._guestConnected = true;
        self._emit('guestConnectionChanged', { connected: true });
        return { success: true };
      },

      installSdk: async (subpath, version) => {
        console.log('[claude-swift] vm.installSdk() subpath=' + subpath + ' version=' + version);
        return { success: true };
      },

      /**
       * Spawn a process - This is called to launch the Claude Code binary
       */
      spawn: (id, processName, command, args, options, envVars, additionalMounts, isResume, allowedDomains, sharedCwdPath) => {
        trace('vm.spawn() id=' + id + ' cmd=' + command + ' args=' + JSON.stringify(args));

        // SECURITY: Validate command is the expected Claude binary
        let hostCommand = command;
        if (command === '/usr/local/bin/claude') {
          hostCommand = path.join(os.homedir(), '.config/Claude/claude-code-vm/2.1.5/claude');
          trace('Translated command: ' + command + ' -> ' + hostCommand);
        } else {
          // SECURITY: Only allow the expected command
          trace('SECURITY: Unexpected command blocked: ' + command);
          if (self._onError) self._onError(id, 'Unexpected command: ' + command, '');
          return { success: false, error: 'Unexpected command' };
        }

        // SECURITY: Verify binary exists and is in expected location
        const expectedDir = path.join(os.homedir(), '.config/Claude/claude-code-vm');
        if (!hostCommand.startsWith(expectedDir)) {
          trace('SECURITY: Command outside expected directory: ' + hostCommand);
          if (self._onError) self._onError(id, 'Invalid binary path', '');
          return { success: false, error: 'Invalid binary path' };
        }

        // Translate VM paths in args with path traversal protection
        let hostArgs = (args || []).map(arg => {
          if (typeof arg === 'string' && arg.startsWith('/sessions/')) {
            // Extract session path component
            const sessionPath = arg.substring('/sessions/'.length);

            // SECURITY: Validate no path traversal
            if (sessionPath.includes('..') || !isPathSafe(SESSIONS_BASE, sessionPath)) {
              trace('SECURITY: Path traversal blocked: ' + arg);
              return arg; // Return original (will fail gracefully)
            }

            const translated = path.join(SESSIONS_BASE, sessionPath);
            trace('Translated arg: ' + arg + ' -> ' + translated);
            return translated;
          }
          return arg;
        });

        // Ensure sessions directory exists with secure permissions
        try {
          if (!fs.existsSync(SESSIONS_BASE)) {
            fs.mkdirSync(SESSIONS_BASE, { recursive: true, mode: 0o700 });
            trace('Created sessions dir: ' + SESSIONS_BASE);
          }
        } catch (e) {
          trace('Failed to create sessions dir: ' + e.message);
        }

        console.log('[claude-swift] vm.spawn() id=' + id + ' cmd=' + hostCommand);
        return self.spawn(id, processName, hostCommand, hostArgs, options, envVars, additionalMounts, isResume, allowedDomains, sharedCwdPath);
      },

      kill: (id, signal) => {
        console.log('[claude-swift] vm.kill(' + id + ', ' + signal + ')');
        return Promise.resolve(self.killProcess(id));
      },

      writeStdin: (id, data) => {
        console.log('[claude-swift] vm.writeStdin(' + id + ')');
        return Promise.resolve(self.writeToProcess(id, data));
      },

      start: () => {
        console.log('[claude-swift] vm.start()');
        self._guestConnected = true;
        self._emit('guestConnectionChanged', { connected: true });
        self._emit('guestReady');
        return Promise.resolve({ success: true });
      },

      stop: () => {
        console.log('[claude-swift] vm.stop()');
        self._guestConnected = false;
        self._emit('guestConnectionChanged', { connected: false });
        return Promise.resolve({ success: true });
      },

      sendCommand: (cmd) => {
        console.log('[claude-swift] vm.sendCommand()', cmd);
        return Promise.resolve({});
      }
    };

    trace('Constructor COMPLETE. vm.setEventCallbacks=' + typeof this.vm.setEventCallbacks);
    console.log('[claude-swift-stub] Constructor complete. vm.setEventCallbacks type:', typeof this.vm.setEventCallbacks);
  }

  // TOP-LEVEL METHODS (for API compatibility)
  setEventCallbacks(onStdout, onStderr, onExit, onError, onNetworkStatus) {
    console.log('[claude-swift] setEventCallbacks() called - REGISTERING CALLBACKS');
    this._onStdout = onStdout;
    this._onStderr = onStderr;
    this._onExit = onExit;
    this._onError = onError;
    this._onNetworkStatus = onNetworkStatus;
    if (this._onNetworkStatus) {
      this._onNetworkStatus('connected');
    }
  }

  async startVM(bundlePath, memoryGB) {
    console.log('[claude-swift] startVM() bundlePath=' + bundlePath + ' memoryGB=' + memoryGB);
    this._guestConnected = true;
    this._emit('guestConnectionChanged', { connected: true });
    return { success: true };
  }

  async installSdk(subpath, version) {
    console.log('[claude-swift] installSdk() subpath=' + subpath + ' version=' + version);
    return { success: true };
  }

  kill(id, signal) {
    console.log('[claude-swift] kill(' + id + ', ' + signal + ')');
    return this.killProcess(id);
  }

  writeStdin(id, data) {
    return this.writeToProcess(id, data);
  }

  spawn(id, processName, command, args, options, envVars, additionalMounts, isResume, allowedDomains, sharedCwdPath) {
    console.log('[claude-swift] spawn() id=' + id + ' cmd=' + command + ' args=' + JSON.stringify(args));
    try {
      // SECURITY: Filter environment variables
      const env = filterEnv(process.env, envVars);
      const cwd = sharedCwdPath || (options && options.cwd) || process.cwd();
      const proc = nodeSpawn(command, args || [], Object.assign({ cwd: cwd, env: env, stdio: ['pipe', 'pipe', 'pipe'] }, options || {}));
      this._processes.set(id, proc);

      const self = this;
      let stdoutBuffer = '';
      let stderrBuffer = '';

      if (proc.stdout) {
        proc.stdout.on('data', function(data) {
          stdoutBuffer += data.toString();
          const lines = stdoutBuffer.split('\n');
          stdoutBuffer = lines.pop();
          for (const line of lines) {
            if (line.trim() && self._onStdout) {
              if (TRACE_IO) {
                trace('stdout line: ' + line.substring(0, 200) + (line.length > 200 ? '...' : ''));
              }
              self._onStdout(id, line + '\n');
            }
          }
        });
      }
      if (proc.stderr) {
        proc.stderr.on('data', function(data) {
          stderrBuffer += data.toString();
          const lines = stderrBuffer.split('\n');
          stderrBuffer = lines.pop();
          for (const line of lines) {
            if (line.trim() && self._onStderr) {
              if (TRACE_IO) {
                trace('stderr line: ' + line.substring(0, 200) + (line.length > 200 ? '...' : ''));
              }
              self._onStderr(id, line + '\n');
            }
          }
        });
      }
      proc.on('exit', function(code, signal) {
        if (stdoutBuffer.trim() && self._onStdout) {
          self._onStdout(id, stdoutBuffer);
        }
        if (stderrBuffer.trim() && self._onStderr) {
          self._onStderr(id, stderrBuffer);
        }
        console.log('[claude-swift] Process ' + id + ' exited: code=' + code + ' signal=' + signal);
        trace('Process ' + id + ' exited: code=' + code);
        if (self._onExit) self._onExit(id, code || 0, signal || '');
        self._processes.delete(id);
      });
      proc.on('error', function(err) {
        console.error('[claude-swift] Process ' + id + ' error:', err);
        if (self._onError) self._onError(id, err.message, err.stack);
      });

      return { success: true, pid: proc.pid };
    } catch (err) {
      console.error('[claude-swift] spawn error:', err);
      if (this._onError) this._onError(id, err.message, err.stack);
      throw err;
    }
  }

  spawnSync(command, args, options) {
    console.log('[claude-swift] spawnSync() cmd=' + command);
    try {
      const result = nodeSpawnSync(command, args || [], Object.assign({ encoding: 'utf-8' }, options || {}));
      return { stdout: result.stdout, stderr: result.stderr, status: result.status, signal: result.signal, error: result.error };
    } catch (err) {
      console.error('[claude-swift] spawnSync error:', err);
      return { error: err, status: 1 };
    }
  }

  stopVM() {
    console.log('[claude-swift] stopVM()');
    for (const entry of this._processes) {
      try { entry[1].kill('SIGTERM'); } catch (e) {}
    }
    this._processes.clear();
    this._guestConnected = false;
    this._emit('guestConnectionChanged', { connected: false });
  }

  killProcess(id) {
    console.log('[claude-swift] killProcess(' + id + ')');
    const proc = this._processes.get(id);
    if (proc) {
      try { proc.kill('SIGTERM'); } catch (e) {}
      this._processes.delete(id);
    }
  }

  cancelProcess(id) {
    return this.killProcess(id);
  }

  writeToProcess(id, data) {
    console.log('[claude-swift] writeToProcess(' + id + ')');
    const proc = this._processes.get(id);
    if (proc && proc.stdin) proc.stdin.write(data);
  }

  _emit(eventName, payload) {
    if (this._eventListener) this._eventListener(eventName, payload);
    this.emit(eventName, payload);
  }

  isGuestConnected() {
    return this._guestConnected;
  }

  getRunningStatus() {
    return { running: this._guestConnected, connected: this._guestConnected };
  }
}

const instance = new SwiftAddonStub();
trace('Instance created. vm=' + typeof instance.vm + ' vm.setEventCallbacks=' + typeof instance.vm.setEventCallbacks);
console.log('[claude-swift-stub] Exporting instance. Instance type:', typeof instance, 'setEventCallbacks:', typeof instance.setEventCallbacks);

module.exports = instance;
module.exports.default = instance;
trace('Module exports set. default.vm.setEventCallbacks=' + typeof module.exports.default.vm.setEventCallbacks);
