# Mount Symlinks Design

## Problem

Claude Cowork on Linux fails with "Path not found" errors because the VM mount points don't exist:

```
stderr: Path /home/zack/.local/share/claude-cowork/sessions/stoic-busy-hawking/mnt/zack was not found.
```

On macOS, Apple's Virtualization Framework creates these mounts automatically. On Linux, we need to create symlinks ourselves.

## Root Cause

The `vm.spawn()` function receives an `additionalMounts` parameter containing mount mappings, but the stub ignores it:

```javascript
// additionalMounts structure (reverse-engineered):
{
  "mountName": {
    path: "relative/path/from/homedir",  // e.g., "dev/project"
    mode: "rw" | "ro"
  }
}
```

Example:
```javascript
{
  ".claude": { path: ".config/Claude/...", mode: "rw" },
  ".skills": { path: ".config/Claude/.../skills-plugin/...", mode: "ro" },
  "zack": { path: "", mode: "rw" },  // "" means homedir itself
  "outputs": { path: ".local/share/.../outputs", mode: "rw" }
}
```

## Solution

### 1. Create Mount Points

When `vm.spawn()` is called, create the session directory structure:

```
~/.local/share/claude-cowork/sessions/<session>/
├── mnt/
│   ├── <folder> → /home/user/<path> (symlink)
│   ├── .claude → ~/.config/Claude/... (symlink)
│   ├── .skills → ~/.config/Claude/.../skills-plugin/... (symlink)
│   └── uploads/ (directory)
└── outputs/ (directory, if needed)
```

### 2. Symlink Logic

For each entry in `additionalMounts`:
- `mountName` = key (e.g., "zack", ".claude", ".skills")
- `hostPath` = `os.homedir() + "/" + additionalMounts[mountName].path`
- `mountPoint` = `SESSIONS_BASE/<session>/mnt/<mountName>`

Special cases:
- If `path` is empty string, it means homedir itself
- `outputs` and `uploads` are directories, not symlinks

### 3. Debug Logging

Add comprehensive logging for:
- Each mount being created
- Source and target paths
- Success/failure of symlink creation
- Final directory structure

## Implementation

Modify `stubs/@ant/claude-swift/js/index.js`:

1. Extract session name from spawn args or processName
2. Parse `additionalMounts` parameter
3. Create mount directories and symlinks before spawning process
4. Add debug logging at each step

## Testing

1. Run `./run.sh` or `./debug.sh`
2. Select a folder in Claude Cowork
3. Verify mount symlinks are created
4. Verify Claude binary starts successfully
5. Verify file operations work (read, write, open)
