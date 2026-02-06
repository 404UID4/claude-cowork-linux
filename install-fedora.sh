#!/bin/bash
# =============================================================================
# install-fedora.sh — Claude Desktop for Linux (Fedora 43 + Wayland + KDE 6.6)
#
# Targeted installer for Fedora 43 running KDE Plasma 6.6 on Wayland.
# Extracts the macOS Claude.dmg, patches it for Linux, and configures
# Electron for native Wayland + KDE 6.6 server-side decorations.
#
# Assumptions (zero dependency checks):
#   - Claude.dmg exists in the current directory
#   - npm is installed and functional
#   - Electron is installed via npm (but Wayland is NOT yet configured)
#   - 7z (p7zip), asar, node are all available
#
# Features:
#   - Multi-step interactive approval (every phase requires confirmation)
#   - High verbosity logging
#   - Automatic backups before any file modification
#   - Reverse/rollback mode: ./install-fedora.sh --reverse
#   - Full validation of every operation
#
# Usage:
#   ./install-fedora.sh             # Normal installation
#   ./install-fedora.sh --reverse   # Undo all changes using backup manifest
#   ./install-fedora.sh --dry-run   # Show what would be done without doing it
#
# License: MIT
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly INSTALLER_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DMG_FILE="$SCRIPT_DIR/Claude.dmg"
readonly INSTALL_DIR="/Applications/Claude.app"
readonly USER_DATA_DIR="$HOME/Library/Application Support/Claude"
readonly USER_LOG_DIR="$HOME/Library/Logs/Claude"
readonly USER_CACHE_DIR="$HOME/Library/Caches/Claude"
readonly ELECTRON_FLAGS_FILE="$HOME/.config/electron-flags.conf"
readonly ELECTRON25_FLAGS_FILE="$HOME/.config/electron25-flags.conf"
readonly KDE_ENV_DIR="$HOME/.config/plasma-workspace/env"
readonly DESKTOP_FILE="$HOME/.local/share/applications/claude.desktop"
readonly BACKUP_DIR="$SCRIPT_DIR/.fedora-install-backups/$(date +%Y%m%d-%H%M%S)"
readonly MANIFEST_FILE="$SCRIPT_DIR/.fedora-install-backups/manifest.txt"
readonly LOG_FILE="$SCRIPT_DIR/.fedora-install-backups/install.log"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Mode flags
DRY_RUN=false
REVERSE_MODE=false

# =============================================================================
# Logging helpers (high verbosity)
# =============================================================================

log_header()  { echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"; \
                echo -e "${BOLD}${CYAN}║  $*${NC}"; \
                echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"; }
log_step()    { echo -e "${BOLD}${BLUE}[STEP]${NC}    $*"; }
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_verbose() { echo -e "${CYAN}[VERBOSE]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
log_backup()  { echo -e "${YELLOW}[BACKUP]${NC}  $*"; }

die() {
    log_error "$@"
    exit 1
}

# Write to both console and log file
log_to_file() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# =============================================================================
# Interactive approval gate — blocks until user explicitly confirms
# =============================================================================

approval_gate() {
    local phase_name="$1"
    local phase_description="$2"

    echo ""
    echo -e "${BOLD}${YELLOW}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${YELLOW}│  APPROVAL REQUIRED: ${phase_name}${NC}"
    echo -e "${BOLD}${YELLOW}└─────────────────────────────────────────────────┘${NC}"
    echo -e "  ${phase_description}"
    echo ""

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would proceed with: $phase_name"
        return 0
    fi

    local response
    read -r -p "  Proceed with ${phase_name}? [yes/no] > " response
    case "${response,,}" in
        yes|y)
            log_success "Approved: $phase_name"
            log_to_file "APPROVED: $phase_name"
            ;;
        *)
            log_warn "Declined: $phase_name — aborting installer"
            log_to_file "DECLINED: $phase_name"
            exit 0
            ;;
    esac
}

# =============================================================================
# Backup helpers — every file we touch gets backed up first
# =============================================================================

init_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    log_verbose "Backup directory: $BACKUP_DIR"
    log_to_file "BACKUP_DIR=$BACKUP_DIR"
}

# Back up a file before modifying it; records entry in the manifest
backup_file() {
    local filepath="$1"
    if [[ ! -e "$filepath" ]]; then
        log_verbose "No existing file to back up: $filepath"
        # Record that this file was newly created (for reverse mode)
        echo "CREATED|$filepath" >> "$MANIFEST_FILE"
        log_to_file "MANIFEST: CREATED $filepath"
        return 0
    fi

    local relative_path="${filepath#/}"
    local backup_dest="$BACKUP_DIR/$relative_path"
    mkdir -p "$(dirname "$backup_dest")"

    if $DRY_RUN; then
        log_backup "[DRY-RUN] Would back up: $filepath -> $backup_dest"
        return 0
    fi

    cp -a "$filepath" "$backup_dest"
    echo "MODIFIED|$filepath|$backup_dest" >> "$MANIFEST_FILE"
    log_backup "Backed up: $filepath"
    log_verbose "  -> $backup_dest"
    log_to_file "MANIFEST: MODIFIED $filepath -> $backup_dest"
}

# Back up an entire directory before replacing it
backup_directory() {
    local dirpath="$1"
    if [[ ! -d "$dirpath" ]]; then
        log_verbose "No existing directory to back up: $dirpath"
        echo "CREATED_DIR|$dirpath" >> "$MANIFEST_FILE"
        log_to_file "MANIFEST: CREATED_DIR $dirpath"
        return 0
    fi

    local relative_path="${dirpath#/}"
    local backup_dest="$BACKUP_DIR/$relative_path"
    mkdir -p "$(dirname "$backup_dest")"

    if $DRY_RUN; then
        log_backup "[DRY-RUN] Would back up directory: $dirpath -> $backup_dest"
        return 0
    fi

    cp -a "$dirpath" "$backup_dest"
    echo "MODIFIED_DIR|$dirpath|$backup_dest" >> "$MANIFEST_FILE"
    log_backup "Backed up directory: $dirpath"
    log_verbose "  -> $backup_dest"
    log_to_file "MANIFEST: MODIFIED_DIR $dirpath -> $backup_dest"
}

# =============================================================================
# Safe execution wrapper — validates each command before and after
# =============================================================================

safe_exec() {
    local description="$1"
    shift

    log_verbose "Executing: $description"
    log_verbose "  Command: $*"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    fi

    if ! "$@"; then
        log_error "Command failed: $description"
        log_error "  Command was: $*"
        log_to_file "FAILED: $description ($*)"
        return 1
    fi

    log_verbose "  Completed: $description"
    log_to_file "SUCCESS: $description"
}

# =============================================================================
# Reverse mode — undo all changes from the manifest
# =============================================================================

reverse_changes() {
    log_header "REVERSE MODE — Undoing Installation Changes"

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        die "No manifest found at $MANIFEST_FILE — nothing to reverse"
    fi

    echo ""
    log_info "Manifest file: $MANIFEST_FILE"
    log_info "The following operations will be reversed:"
    echo ""

    # Show what will be reversed
    local line_count=0
    while IFS='|' read -r action filepath backup_path; do
        case "$action" in
            CREATED)
                echo -e "  ${RED}[DELETE]${NC}  $filepath  (was newly created)"
                ;;
            CREATED_DIR)
                echo -e "  ${RED}[RMDIR]${NC}  $filepath  (was newly created)"
                ;;
            MODIFIED)
                echo -e "  ${YELLOW}[RESTORE]${NC} $filepath  (from $backup_path)"
                ;;
            MODIFIED_DIR)
                echo -e "  ${YELLOW}[RESTORE]${NC} $filepath  (from $backup_path)"
                ;;
        esac
        line_count=$((line_count + 1))
    done < "$MANIFEST_FILE"

    if [[ $line_count -eq 0 ]]; then
        log_warn "Manifest is empty — nothing to reverse"
        return 0
    fi

    echo ""
    log_warn "This will undo $line_count recorded operations."

    local response
    read -r -p "  Proceed with reversal? [yes/no] > " response
    case "${response,,}" in
        yes|y) ;;
        *)
            log_info "Reversal cancelled."
            return 0
            ;;
    esac

    # Second confirmation for safety
    echo ""
    log_warn "FINAL CONFIRMATION: All changes listed above will be reversed."
    read -r -p "  Type 'REVERSE' to confirm > " response
    if [[ "$response" != "REVERSE" ]]; then
        log_info "Reversal cancelled (confirmation text did not match)."
        return 0
    fi

    echo ""
    log_step "Reversing changes..."

    # Process manifest in reverse order (LIFO) for correct undo sequencing
    local tmpfile
    tmpfile=$(mktemp)
    tac "$MANIFEST_FILE" > "$tmpfile"

    while IFS='|' read -r action filepath backup_path; do
        case "$action" in
            CREATED)
                if [[ -e "$filepath" ]]; then
                    # Use sudo if path requires it
                    if [[ "$filepath" == /Applications/* ]] || [[ "$filepath" == /usr/* ]]; then
                        sudo rm -f "$filepath" && log_success "Removed (sudo): $filepath" \
                            || log_error "Failed to remove: $filepath"
                    else
                        rm -f "$filepath" && log_success "Removed: $filepath" \
                            || log_error "Failed to remove: $filepath"
                    fi
                else
                    log_verbose "Already absent: $filepath"
                fi
                ;;
            CREATED_DIR)
                if [[ -d "$filepath" ]]; then
                    if [[ "$filepath" == /Applications/* ]] || [[ "$filepath" == /usr/* ]]; then
                        sudo rm -rf "$filepath" && log_success "Removed directory (sudo): $filepath" \
                            || log_error "Failed to remove directory: $filepath"
                    else
                        rm -rf "$filepath" && log_success "Removed directory: $filepath" \
                            || log_error "Failed to remove directory: $filepath"
                    fi
                else
                    log_verbose "Already absent: $filepath"
                fi
                ;;
            MODIFIED)
                if [[ -f "$backup_path" ]]; then
                    if [[ "$filepath" == /Applications/* ]] || [[ "$filepath" == /usr/* ]]; then
                        sudo cp -a "$backup_path" "$filepath" && log_success "Restored (sudo): $filepath" \
                            || log_error "Failed to restore: $filepath"
                    else
                        cp -a "$backup_path" "$filepath" && log_success "Restored: $filepath" \
                            || log_error "Failed to restore: $filepath"
                    fi
                else
                    log_error "Backup not found: $backup_path (cannot restore $filepath)"
                fi
                ;;
            MODIFIED_DIR)
                if [[ -d "$backup_path" ]]; then
                    if [[ "$filepath" == /Applications/* ]] || [[ "$filepath" == /usr/* ]]; then
                        sudo rm -rf "$filepath"
                        sudo cp -a "$backup_path" "$filepath" && log_success "Restored directory (sudo): $filepath" \
                            || log_error "Failed to restore directory: $filepath"
                    else
                        rm -rf "$filepath"
                        cp -a "$backup_path" "$filepath" && log_success "Restored directory: $filepath" \
                            || log_error "Failed to restore directory: $filepath"
                    fi
                else
                    log_error "Backup not found: $backup_path (cannot restore $filepath)"
                fi
                ;;
        esac
    done < "$tmpfile"

    rm -f "$tmpfile"

    # Remove the symlink
    if [[ -L /usr/local/bin/claude ]]; then
        sudo rm -f /usr/local/bin/claude && log_success "Removed symlink: /usr/local/bin/claude"
    fi

    echo ""
    log_success "Reversal complete."
    log_info "Backups are preserved in: $BACKUP_DIR"
    log_info "You may delete them manually when satisfied."
}

# =============================================================================
# Phase 0: Parse arguments and show banner
# =============================================================================

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --reverse|--rollback|--undo)
                REVERSE_MODE=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --help|-h)
                echo "Usage: $0 [--reverse|--dry-run|--help]"
                echo ""
                echo "  (no args)    Run the Fedora 43 + KDE 6.6 + Wayland installer"
                echo "  --reverse    Undo a previous installation using the backup manifest"
                echo "  --dry-run    Show what would be done without making changes"
                echo "  --help       Show this help message"
                exit 0
                ;;
            *)
                die "Unknown argument: $arg (use --help for usage)"
                ;;
        esac
    done
}

show_banner() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║     Claude Desktop for Linux — Fedora 43 Installer         ║"
    echo "║     Wayland + KDE Plasma 6.6                               ║"
    echo "║     Version: ${INSTALLER_VERSION}                                        ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN MODE] No changes will be made.${NC}"
        echo ""
    fi

    log_info "Installer version: $INSTALLER_VERSION"
    log_info "Script directory:  $SCRIPT_DIR"
    log_info "Target platform:   Fedora 43 / KDE Plasma 6.6 / Wayland"
    log_info "Date:              $(date)"
    log_info "User:              $(whoami)"
    echo ""
}

# =============================================================================
# Phase 1: Pre-flight validation (no dependency checks, just file verification)
# =============================================================================

phase_preflight() {
    log_header "Phase 1/8: Pre-flight Validation"

    # Verify Claude.dmg exists
    log_step "Checking for Claude.dmg..."
    if [[ ! -f "$DMG_FILE" ]]; then
        die "Claude.dmg not found at: $DMG_FILE\n  Place Claude.dmg in the script directory and re-run."
    fi
    local dmg_size
    dmg_size=$(stat -c%s "$DMG_FILE" 2>/dev/null || echo 0)
    log_success "Found: Claude.dmg ($(numfmt --to=iec "$dmg_size" 2>/dev/null || echo "${dmg_size} bytes"))"

    # Verify stubs exist in the repo
    log_step "Checking for Linux stubs..."
    local swift_stub="$SCRIPT_DIR/stubs/@ant/claude-swift/js/index.js"
    local native_stub="$SCRIPT_DIR/stubs/@ant/claude-native/index.js"

    if [[ ! -f "$swift_stub" ]]; then
        die "Swift stub not found at: $swift_stub"
    fi
    log_success "Found: Swift Linux stub ($swift_stub)"

    if [[ ! -f "$native_stub" ]]; then
        die "Native stub not found at: $native_stub"
    fi
    log_success "Found: Native Linux stub ($native_stub)"

    # Verify linux-loader.js exists
    log_step "Checking for linux-loader.js..."
    if [[ ! -f "$SCRIPT_DIR/linux-loader.js" ]]; then
        die "linux-loader.js not found at: $SCRIPT_DIR/linux-loader.js"
    fi
    log_success "Found: linux-loader.js"

    # Verify we are NOT root
    if [[ $EUID -eq 0 ]]; then
        die "Do not run as root. The script will use sudo when needed."
    fi
    log_success "Running as regular user (sudo will be used where needed)"

    # Display environment summary
    log_step "Environment summary:"
    log_verbose "  WAYLAND_DISPLAY:        ${WAYLAND_DISPLAY:-<not set>}"
    log_verbose "  XDG_SESSION_TYPE:       ${XDG_SESSION_TYPE:-<not set>}"
    log_verbose "  XDG_CURRENT_DESKTOP:    ${XDG_CURRENT_DESKTOP:-<not set>}"
    log_verbose "  XDG_SESSION_DESKTOP:    ${XDG_SESSION_DESKTOP:-<not set>}"
    log_verbose "  DESKTOP_SESSION:        ${DESKTOP_SESSION:-<not set>}"
    log_verbose "  KDE_FULL_SESSION:       ${KDE_FULL_SESSION:-<not set>}"
    log_verbose "  KDE_SESSION_VERSION:    ${KDE_SESSION_VERSION:-<not set>}"
    log_verbose "  ELECTRON_OZONE_PLATFORM_HINT: ${ELECTRON_OZONE_PLATFORM_HINT:-<not set>}"

    log_success "Pre-flight validation passed"
}

# =============================================================================
# Phase 2: Extract DMG and app.asar
# =============================================================================

phase_extract() {
    log_header "Phase 2/8: Extract Claude.dmg"

    approval_gate "DMG Extraction" \
        "Extract Claude.dmg and app.asar to a temporary working directory."

    local extract_dir="$SCRIPT_DIR/.fedora-extract-$(date +%s)"
    local app_extract_dir="$SCRIPT_DIR/.fedora-app-extracted"

    # Extract DMG
    log_step "Extracting DMG with 7z..."
    log_verbose "  Source: $DMG_FILE"
    log_verbose "  Target: $extract_dir"

    if ! $DRY_RUN; then
        mkdir -p "$extract_dir"
        safe_exec "7z extract DMG" 7z x -y -o"$extract_dir" "$DMG_FILE" >/dev/null 2>&1
    fi

    # Find Claude.app inside extracted DMG
    local claude_app
    if ! $DRY_RUN; then
        claude_app=$(find "$extract_dir" -name "Claude.app" -type d | head -1)
        if [[ -z "$claude_app" ]]; then
            die "Claude.app not found inside DMG"
        fi
        log_success "Found Claude.app in DMG: $claude_app"
    else
        log_info "[DRY-RUN] Would find Claude.app inside extracted DMG"
        claude_app="$extract_dir/Claude.app"
    fi

    # Extract app.asar
    log_step "Extracting app.asar..."
    if ! $DRY_RUN; then
        local asar_file="$claude_app/Contents/Resources/app.asar"
        if [[ ! -f "$asar_file" ]]; then
            die "app.asar not found at: $asar_file"
        fi

        rm -rf "$app_extract_dir"
        safe_exec "asar extract" asar extract "$asar_file" "$app_extract_dir"
        local extracted_size
        extracted_size=$(du -sh "$app_extract_dir" | cut -f1)
        log_success "Extracted $extracted_size of app code to $app_extract_dir"
    else
        log_info "[DRY-RUN] Would extract app.asar"
    fi

    # Export paths for subsequent phases
    CLAUDE_APP_PATH="$claude_app"
    APP_EXTRACT_PATH="$app_extract_dir"
    EXTRACT_DIR_PATH="$extract_dir"
    log_success "Phase 2 complete: DMG extracted"
}

# =============================================================================
# Phase 3: Create application structure at /Applications/Claude.app
# =============================================================================

phase_install_app() {
    log_header "Phase 3/8: Install Application Structure"

    echo ""
    log_info "The following will be created with sudo:"
    echo "  • $INSTALL_DIR/Contents/MacOS/       (launcher script)"
    echo "  • $INSTALL_DIR/Contents/Resources/    (app code, stubs, loader)"
    echo "  • $INSTALL_DIR/Contents/Frameworks/   (empty, for compatibility)"
    echo "  • /usr/local/bin/claude               (symlink to launcher)"
    echo ""

    approval_gate "Application Installation" \
        "Create $INSTALL_DIR and install application files (requires sudo)."

    # Back up existing installation
    backup_directory "$INSTALL_DIR"

    if ! $DRY_RUN; then
        # Remove old installation
        if [[ -d "$INSTALL_DIR" ]]; then
            log_verbose "Removing previous installation..."
            sudo rm -rf "$INSTALL_DIR"
        fi

        # Create directory structure
        log_step "Creating application directory structure..."
        sudo mkdir -p "$INSTALL_DIR/Contents/"{MacOS,Resources,Frameworks}
        log_verbose "  Created: $INSTALL_DIR/Contents/MacOS"
        log_verbose "  Created: $INSTALL_DIR/Contents/Resources"
        log_verbose "  Created: $INSTALL_DIR/Contents/Frameworks"

        # Copy extracted app code
        log_step "Copying app code..."
        sudo cp -r "$APP_EXTRACT_PATH" "$INSTALL_DIR/Contents/Resources/app"
        log_success "App code installed"

        # Copy resources from original Claude.app
        log_step "Copying original resources (icons, locales, etc.)..."
        sudo cp -r "$CLAUDE_APP_PATH/Contents/Resources/"* "$INSTALL_DIR/Contents/Resources/" 2>/dev/null || true
        log_success "Resources copied"

        # Install Swift stub
        log_step "Installing Swift Linux stub..."
        sudo mkdir -p "$INSTALL_DIR/Contents/Resources/stubs/@ant/claude-swift/js"
        sudo cp "$SCRIPT_DIR/stubs/@ant/claude-swift/js/index.js" \
                "$INSTALL_DIR/Contents/Resources/stubs/@ant/claude-swift/js/index.js"
        # Replace original module
        sudo cp "$SCRIPT_DIR/stubs/@ant/claude-swift/js/index.js" \
                "$INSTALL_DIR/Contents/Resources/app/node_modules/@ant/claude-swift/js/index.js"
        log_success "Swift stub installed and original module replaced"

        # Install Native stub
        log_step "Installing Native Linux stub..."
        sudo mkdir -p "$INSTALL_DIR/Contents/Resources/stubs/@ant/claude-native"
        sudo cp "$SCRIPT_DIR/stubs/@ant/claude-native/index.js" \
                "$INSTALL_DIR/Contents/Resources/stubs/@ant/claude-native/index.js"
        sudo cp "$SCRIPT_DIR/stubs/@ant/claude-native/index.js" \
                "$INSTALL_DIR/Contents/Resources/app/node_modules/@ant/claude-native/index.js"
        log_success "Native stub installed and original module replaced"

        # Copy .vite build
        log_step "Copying .vite build directory..."
        sudo cp -r "$APP_EXTRACT_PATH/.vite" "$INSTALL_DIR/Contents/Resources/.vite"
        log_success ".vite build copied"

        # Install linux-loader.js
        log_step "Installing linux-loader.js..."
        sudo cp "$SCRIPT_DIR/linux-loader.js" "$INSTALL_DIR/Contents/Resources/linux-loader.js"
        sudo chmod +x "$INSTALL_DIR/Contents/Resources/linux-loader.js"
        log_success "Linux loader installed"

        # Copy locale files to Electron resources directories
        log_step "Installing locale files to Electron resource directories..."
        local locale_count=0
        for electron_dir in /usr/lib/electron*/resources; do
            if [[ -d "$electron_dir" ]]; then
                sudo cp "$CLAUDE_APP_PATH/Contents/Resources/"*.json "$electron_dir/" 2>/dev/null || true
                locale_count=$((locale_count + 1))
                log_verbose "  Installed locales to: $electron_dir"
            fi
        done
        if [[ $locale_count -gt 0 ]]; then
            log_success "Locale files installed to $locale_count Electron installation(s)"
        else
            log_verbose "No system Electron resource directories found (npm-installed Electron used)"
        fi
    fi

    log_success "Phase 3 complete: Application structure created"
}

# =============================================================================
# Phase 4: Create launcher script with Wayland + KDE 6.6 support
# =============================================================================

phase_create_launcher() {
    log_header "Phase 4/8: Create Launcher Script"

    approval_gate "Launcher Creation" \
        "Create the Claude launch script with Wayland + KDE 6.6 optimizations."

    local launcher_path="$INSTALL_DIR/Contents/MacOS/Claude"

    if ! $DRY_RUN; then
        log_step "Writing launcher script to $launcher_path..."

        sudo tee "$launcher_path" > /dev/null << 'LAUNCHER_EOF'
#!/bin/bash
# =============================================================================
# Claude Desktop Launcher — Fedora 43 / Wayland / KDE Plasma 6.6
# =============================================================================

# Resolve symlinks to find actual installation
SCRIPT_PATH="$0"
while [ -L "$SCRIPT_PATH" ]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done

SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/../Resources"
cd "$RESOURCES_DIR" || exit 1

# Parse arguments
ELECTRON_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --debug)
            export CLAUDE_TRACE=1
            echo "[Claude] Debug trace logging enabled"
            ;;
        --devtools)
            ELECTRON_ARGS+=("--inspect")
            echo "[Claude] DevTools enabled (--inspect)"
            ;;
        --isolate-network)
            export CLAUDE_ISOLATE_NETWORK=1
            echo "[Claude] Network isolation enabled"
            ;;
        --x11)
            # Force X11 (XWayland) backend as an escape hatch
            export ELECTRON_OZONE_PLATFORM_HINT=x11
            echo "[Claude] Forcing X11 backend"
            ;;
        *)
            ELECTRON_ARGS+=("$arg")
            ;;
    esac
done

# Enable Electron logging
export ELECTRON_ENABLE_LOGGING=1

# ---------------------------------------------------------------------------
# Wayland + KDE 6.6 Configuration
# ---------------------------------------------------------------------------
# Detect Wayland session and configure Electron's Ozone platform accordingly.
# KDE Plasma 6.6 on Fedora 43 uses server-side decorations (SSD) by default.
# We enable WaylandWindowDecorations so Electron windows get proper title bars.

if [[ -n "${WAYLAND_DISPLAY:-}" ]] || [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    # Use Wayland backend via Ozone
    export ELECTRON_OZONE_PLATFORM_HINT="${ELECTRON_OZONE_PLATFORM_HINT:-wayland}"
    echo "[Claude] Wayland session detected — Ozone platform: $ELECTRON_OZONE_PLATFORM_HINT"

    desktop_env="${XDG_CURRENT_DESKTOP:-}${XDG_SESSION_DESKTOP:-}${DESKTOP_SESSION:-}"

    if [[ "${desktop_env,,}" == *kde* ]] || [[ "${desktop_env,,}" == *plasma* ]]; then
        echo "[Claude] KDE Plasma detected — enabling Wayland window decorations"

        # Server-side decorations for KDE 6.6
        ELECTRON_ARGS+=("--enable-features=WaylandWindowDecorations")

        # Use the Wayland input method for KDE
        ELECTRON_ARGS+=("--ozone-platform-hint=auto")

        # Enable Wayland IME support for KDE
        ELECTRON_ARGS+=("--enable-wayland-ime")
    fi

    # GPU acceleration on Wayland (Fedora 43 defaults to PipeWire + Wayland)
    ELECTRON_ARGS+=("--enable-gpu-rasterization")
    ELECTRON_ARGS+=("--enable-zero-copy")
fi

# Ensure log directory exists
mkdir -p ~/Library/Logs/Claude

# Launch Electron with the linux-loader.js entry point
exec electron linux-loader.js "${ELECTRON_ARGS[@]}" 2>&1 | tee -a ~/Library/Logs/Claude/startup.log
LAUNCHER_EOF

        sudo chmod +x "$launcher_path"
        log_success "Launcher script created: $launcher_path"

        # Create symlink in PATH
        log_step "Creating symlink in /usr/local/bin..."
        backup_file "/usr/local/bin/claude"
        sudo ln -sf "$launcher_path" /usr/local/bin/claude
        log_success "Symlink created: /usr/local/bin/claude -> $launcher_path"
    fi

    log_success "Phase 4 complete: Launcher created with Wayland + KDE 6.6 support"
}

# =============================================================================
# Phase 5: Configure Electron for Wayland on Fedora 43 / KDE 6.6
# =============================================================================

phase_configure_wayland() {
    log_header "Phase 5/8: Configure Electron for Wayland"

    echo ""
    log_info "Electron Wayland configuration files to be created/updated:"
    echo "  • $ELECTRON_FLAGS_FILE"
    echo "  • $ELECTRON25_FLAGS_FILE"
    echo "  • $KDE_ENV_DIR/electron-wayland.sh"
    echo ""

    approval_gate "Wayland Configuration" \
        "Create Electron flags files and a KDE Plasma env script for Wayland."

    # --- electron-flags.conf ---
    log_step "Configuring $ELECTRON_FLAGS_FILE..."
    backup_file "$ELECTRON_FLAGS_FILE"

    if ! $DRY_RUN; then
        mkdir -p "$(dirname "$ELECTRON_FLAGS_FILE")"
        cat > "$ELECTRON_FLAGS_FILE" << 'ELECTRON_FLAGS_EOF'
# Electron flags for Wayland + KDE Plasma 6.6 (Fedora 43)
# Generated by install-fedora.sh — Claude Desktop for Linux
# See: https://wiki.archlinux.org/title/Wayland#Electron
--ozone-platform-hint=auto
--enable-features=WaylandWindowDecorations
--enable-wayland-ime
--enable-gpu-rasterization
--enable-zero-copy
ELECTRON_FLAGS_EOF
        log_success "Created: $ELECTRON_FLAGS_FILE"
    fi

    # --- electron25-flags.conf (used by some Electron apps) ---
    log_step "Configuring $ELECTRON25_FLAGS_FILE..."
    backup_file "$ELECTRON25_FLAGS_FILE"

    if ! $DRY_RUN; then
        mkdir -p "$(dirname "$ELECTRON25_FLAGS_FILE")"
        cat > "$ELECTRON25_FLAGS_FILE" << 'ELECTRON25_FLAGS_EOF'
# Electron 25+ flags for Wayland + KDE Plasma 6.6 (Fedora 43)
# Generated by install-fedora.sh — Claude Desktop for Linux
--ozone-platform-hint=auto
--enable-features=WaylandWindowDecorations
--enable-wayland-ime
--enable-gpu-rasterization
--enable-zero-copy
ELECTRON25_FLAGS_EOF
        log_success "Created: $ELECTRON25_FLAGS_FILE"
    fi

    # --- KDE Plasma environment script ---
    log_step "Configuring KDE Plasma Wayland environment..."
    local kde_env_script="$KDE_ENV_DIR/electron-wayland.sh"
    backup_file "$kde_env_script"

    if ! $DRY_RUN; then
        mkdir -p "$KDE_ENV_DIR"
        cat > "$kde_env_script" << 'KDE_ENV_EOF'
#!/bin/sh
# Set Electron Ozone platform for all Electron apps on Wayland under KDE 6.6
# Generated by install-fedora.sh — Claude Desktop for Linux
export ELECTRON_OZONE_PLATFORM_HINT=auto
KDE_ENV_EOF
        chmod +x "$kde_env_script"
        log_success "Created: $kde_env_script"
    fi

    log_success "Phase 5 complete: Electron configured for Wayland"
}

# =============================================================================
# Phase 6: Setup user directories
# =============================================================================

phase_setup_user_dirs() {
    log_header "Phase 6/8: Setup User Directories"

    approval_gate "User Directory Setup" \
        "Create macOS-style directories under ~/Library for Claude data, logs, and cache."

    if ! $DRY_RUN; then
        log_step "Creating application data directories..."

        local dirs=(
            "$USER_DATA_DIR/Projects"
            "$USER_DATA_DIR/Conversations"
            "$USER_DATA_DIR/Claude Extensions"
            "$USER_DATA_DIR/Claude Extensions Settings"
            "$USER_DATA_DIR/claude-code-vm"
            "$USER_DATA_DIR/vm_bundles"
            "$USER_DATA_DIR/blob_storage"
            "$USER_LOG_DIR"
            "$USER_CACHE_DIR"
            "$HOME/Library/Preferences"
        )

        for dir in "${dirs[@]}"; do
            if [[ ! -d "$dir" ]]; then
                mkdir -p "$dir"
                echo "CREATED_DIR|$dir" >> "$MANIFEST_FILE"
                log_verbose "  Created: $dir"
            else
                log_verbose "  Exists:  $dir"
            fi
        done

        # Create default config.json
        log_step "Creating default configuration files..."
        if [[ ! -f "$USER_DATA_DIR/config.json" ]]; then
            cat > "$USER_DATA_DIR/config.json" << 'CONFIG_JSON_EOF'
{
  "scale": 0,
  "locale": "en-US",
  "userThemeMode": "system",
  "hasTrackedInitialActivation": false
}
CONFIG_JSON_EOF
            echo "CREATED|$USER_DATA_DIR/config.json" >> "$MANIFEST_FILE"
            log_success "Created: config.json"
        else
            log_verbose "config.json already exists (preserved)"
        fi

        # Create default desktop config
        if [[ ! -f "$USER_DATA_DIR/claude_desktop_config.json" ]]; then
            cat > "$USER_DATA_DIR/claude_desktop_config.json" << 'DESKTOP_CONFIG_EOF'
{
  "preferences": {
    "chromeExtensionEnabled": true
  }
}
DESKTOP_CONFIG_EOF
            echo "CREATED|$USER_DATA_DIR/claude_desktop_config.json" >> "$MANIFEST_FILE"
            log_success "Created: claude_desktop_config.json"
        else
            log_verbose "claude_desktop_config.json already exists (preserved)"
        fi

        # Set secure permissions
        log_step "Setting directory permissions (700)..."
        chmod 700 "$USER_DATA_DIR" "$USER_LOG_DIR" "$USER_CACHE_DIR"
        log_success "Permissions set: 700 on data, log, and cache directories"
    fi

    log_success "Phase 6 complete: User directories ready"
}

# =============================================================================
# Phase 7: Create desktop entry
# =============================================================================

phase_desktop_entry() {
    log_header "Phase 7/8: Create Desktop Entry"

    approval_gate "Desktop Entry" \
        "Create a .desktop file so Claude appears in your KDE application menu."

    backup_file "$DESKTOP_FILE"

    if ! $DRY_RUN; then
        log_step "Creating .desktop entry..."
        mkdir -p "$(dirname "$DESKTOP_FILE")"

        cat > "$DESKTOP_FILE" << DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Claude
Comment=AI assistant by Anthropic
Exec=/usr/local/bin/claude
Icon=$INSTALL_DIR/Contents/Resources/icon.icns
Terminal=false
Categories=Utility;Development;Chat;
Keywords=AI;assistant;chat;anthropic;
StartupWMClass=Claude
DESKTOP_EOF

        chmod +x "$DESKTOP_FILE"
        log_success "Created: $DESKTOP_FILE"

        # Update desktop database
        if command -v update-desktop-database >/dev/null 2>&1; then
            log_verbose "Updating desktop database..."
            update-desktop-database ~/.local/share/applications 2>/dev/null || true
            log_success "Desktop database updated"
        fi
    fi

    log_success "Phase 7 complete: Desktop entry created"
}

# =============================================================================
# Phase 8: Verification and cleanup
# =============================================================================

phase_verify_and_cleanup() {
    log_header "Phase 8/8: Verification & Cleanup"

    approval_gate "Final Verification" \
        "Verify installation integrity, clean up temporary files, and show summary."

    local all_ok=true

    # Verify application structure
    log_step "Verifying application structure..."

    local check_paths=(
        "$INSTALL_DIR/Contents/MacOS/Claude"
        "$INSTALL_DIR/Contents/Resources/linux-loader.js"
        "$INSTALL_DIR/Contents/Resources/app/.vite/build/index.js"
        "$INSTALL_DIR/Contents/Resources/stubs/@ant/claude-swift/js/index.js"
        "$INSTALL_DIR/Contents/Resources/stubs/@ant/claude-native/index.js"
    )

    if ! $DRY_RUN; then
        for path in "${check_paths[@]}"; do
            if [[ -e "$path" ]]; then
                log_success "Verified: $path"
            else
                log_error "Missing:  $path"
                all_ok=false
            fi
        done
    fi

    # Verify symlink
    log_step "Verifying /usr/local/bin/claude symlink..."
    if ! $DRY_RUN; then
        if [[ -L /usr/local/bin/claude ]]; then
            log_success "Symlink OK: $(readlink /usr/local/bin/claude)"
        else
            log_warn "Symlink not found at /usr/local/bin/claude"
            all_ok=false
        fi
    fi

    # Verify Wayland configuration
    log_step "Verifying Wayland configuration files..."
    if ! $DRY_RUN; then
        if [[ -f "$ELECTRON_FLAGS_FILE" ]]; then
            log_success "Verified: $ELECTRON_FLAGS_FILE"
        else
            log_warn "Missing: $ELECTRON_FLAGS_FILE"
            all_ok=false
        fi

        if [[ -f "$ELECTRON25_FLAGS_FILE" ]]; then
            log_success "Verified: $ELECTRON25_FLAGS_FILE"
        else
            log_warn "Missing: $ELECTRON25_FLAGS_FILE"
            all_ok=false
        fi
    fi

    # Verify user directories
    log_step "Verifying user directories..."
    if ! $DRY_RUN; then
        for dir in "$USER_DATA_DIR" "$USER_LOG_DIR" "$USER_CACHE_DIR"; do
            if [[ -d "$dir" ]]; then
                local perms
                perms=$(stat -c '%a' "$dir" 2>/dev/null || echo "???")
                log_success "Verified: $dir (permissions: $perms)"
            else
                log_warn "Missing: $dir"
                all_ok=false
            fi
        done
    fi

    # Verify desktop entry
    log_step "Verifying desktop entry..."
    if ! $DRY_RUN; then
        if [[ -f "$DESKTOP_FILE" ]]; then
            log_success "Verified: $DESKTOP_FILE"
        else
            log_warn "Missing: $DESKTOP_FILE"
            all_ok=false
        fi
    fi

    # Clean up temporary extraction directory
    log_step "Cleaning up temporary files..."
    if ! $DRY_RUN; then
        if [[ -n "${EXTRACT_DIR_PATH:-}" ]] && [[ -d "${EXTRACT_DIR_PATH:-}" ]]; then
            rm -rf "$EXTRACT_DIR_PATH"
            log_success "Removed temporary extraction: $EXTRACT_DIR_PATH"
        fi

        if [[ -n "${APP_EXTRACT_PATH:-}" ]] && [[ -d "${APP_EXTRACT_PATH:-}" ]]; then
            rm -rf "$APP_EXTRACT_PATH"
            log_success "Removed temporary app extract: $APP_EXTRACT_PATH"
        fi
    fi

    # Final status
    echo ""
    if $all_ok || $DRY_RUN; then
        echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${GREEN}║  ✓  Installation Complete!                                  ║${NC}"
        echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${YELLOW}║  ⚠  Installation completed with warnings (see above)       ║${NC}"
        echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    fi

    echo ""
    log_info "Installation summary:"
    echo "  Application:    $INSTALL_DIR"
    echo "  Data:           $USER_DATA_DIR"
    echo "  Logs:           $USER_LOG_DIR"
    echo "  Cache:          $USER_CACHE_DIR"
    echo "  Electron flags: $ELECTRON_FLAGS_FILE"
    echo "  Desktop entry:  $DESKTOP_FILE"
    echo "  Backups:        $BACKUP_DIR"
    echo "  Manifest:       $MANIFEST_FILE"
    echo ""
    log_info "Launch Claude:"
    echo "  Command:   claude"
    echo "  Desktop:   Search for 'Claude' in KDE application launcher"
    echo ""
    log_info "Launch options:"
    echo "  claude --debug        Enable trace logging"
    echo "  claude --devtools     Enable Chrome DevTools"
    echo "  claude --x11          Force X11 (XWayland) backend"
    echo ""
    log_info "To undo this installation:"
    echo "  ./install-fedora.sh --reverse"
    echo ""
    log_info "Startup log: ~/Library/Logs/Claude/startup.log"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"

    # Handle reverse mode
    if $REVERSE_MODE; then
        reverse_changes
        exit 0
    fi

    show_banner
    init_backup_dir

    phase_preflight
    phase_extract
    phase_install_app
    phase_create_launcher
    phase_configure_wayland
    phase_setup_user_dirs
    phase_desktop_entry
    phase_verify_and_cleanup
}

main "$@"
