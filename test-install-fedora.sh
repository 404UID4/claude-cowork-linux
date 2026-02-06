#!/bin/bash
# =============================================================================
# test-install-fedora.sh — Validation tests for install-fedora.sh
#
# Tests the Fedora 43 + Wayland + KDE 6.6 installer script for:
#   - Syntax correctness
#   - Required features (backup, reverse, approval gates, Wayland config)
#   - Safety invariants (no raw dependency checks, backup before modify, etc.)
#
# Usage:  ./test-install-fedora.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALLER="$SCRIPT_DIR/install-fedora.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; FAILURES=$((FAILURES + 1)); }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }

FAILURES=0

echo "=== install-fedora.sh Validation Tests ==="
echo ""

# ----------------------------------------------------------------
# Test 1: Script exists and is executable
# ----------------------------------------------------------------
echo "[TEST 1] Script exists and is executable"
if [[ -f "$INSTALLER" ]]; then
    pass "install-fedora.sh exists"
else
    fail "install-fedora.sh not found"
fi
if [[ -x "$INSTALLER" ]]; then
    pass "install-fedora.sh is executable"
else
    fail "install-fedora.sh is not executable"
fi
echo ""

# ----------------------------------------------------------------
# Test 2: Bash syntax check
# ----------------------------------------------------------------
echo "[TEST 2] Bash syntax check"
if bash -n "$INSTALLER" 2>/dev/null; then
    pass "Syntax OK"
else
    fail "Syntax errors detected"
fi
echo ""

# ----------------------------------------------------------------
# Test 3: No dependency installation commands (zero dependency checks)
# ----------------------------------------------------------------
echo "[TEST 3] Zero dependency checks (no install commands)"
if grep -qE 'dnf install|apt-get install|pacman -S|zypper install' "$INSTALLER"; then
    fail "Found package manager install commands — should assume deps are present"
else
    pass "No dependency installation commands found"
fi
echo ""

# ----------------------------------------------------------------
# Test 4: Expects Claude.dmg filename exactly
# ----------------------------------------------------------------
echo "[TEST 4] Expects 'Claude.dmg' filename"
if grep -q 'Claude\.dmg' "$INSTALLER"; then
    pass "References Claude.dmg"
else
    fail "Does not reference Claude.dmg"
fi
# Should NOT search for Claude-2-*.dmg or other patterns
if grep -q 'Claude-2-\*' "$INSTALLER"; then
    fail "Contains wildcard DMG pattern (should assume exact filename)"
else
    pass "No wildcard DMG patterns"
fi
echo ""

# ----------------------------------------------------------------
# Test 5: Multi-step interactive approval gates
# ----------------------------------------------------------------
echo "[TEST 5] Multi-step interactive approval gates"
approval_count=$(grep -c 'approval_gate' "$INSTALLER" || echo 0)
# Subtract the function definition itself (1 occurrence)
# The function definition line is: approval_gate()
gate_calls=$((approval_count - 1))
if [[ $gate_calls -ge 5 ]]; then
    pass "Found $gate_calls approval gates (multi-step confirmation)"
else
    fail "Only found $gate_calls approval gates (expected >= 5 for multi-step)"
fi
echo ""

# ----------------------------------------------------------------
# Test 6: High verbosity logging
# ----------------------------------------------------------------
echo "[TEST 6] High verbosity logging"
if grep -q 'log_verbose' "$INSTALLER"; then
    pass "Verbose logging function present"
else
    fail "No verbose logging found"
fi
verbose_count=$(grep -c 'log_verbose' "$INSTALLER" || echo 0)
if [[ $verbose_count -ge 10 ]]; then
    pass "Found $verbose_count verbose log calls (high verbosity)"
else
    fail "Only $verbose_count verbose log calls (expected >= 10 for high verbosity)"
fi
echo ""

# ----------------------------------------------------------------
# Test 7: Backup functionality
# ----------------------------------------------------------------
echo "[TEST 7] Backup before modification"
if grep -q 'backup_file' "$INSTALLER"; then
    pass "backup_file function present"
else
    fail "No backup_file function"
fi
if grep -q 'backup_directory' "$INSTALLER"; then
    pass "backup_directory function present"
else
    fail "No backup_directory function"
fi
if grep -q 'MANIFEST_FILE' "$INSTALLER"; then
    pass "Backup manifest tracking present"
else
    fail "No backup manifest tracking"
fi
echo ""

# ----------------------------------------------------------------
# Test 8: Reverse changes feature
# ----------------------------------------------------------------
echo "[TEST 8] Reverse/rollback feature"
if grep -q 'reverse_changes' "$INSTALLER"; then
    pass "reverse_changes function present"
else
    fail "No reverse_changes function"
fi
if grep -q '\-\-reverse' "$INSTALLER"; then
    pass "--reverse flag handled"
else
    fail "No --reverse flag handling"
fi
# Reverse should require double confirmation
if grep -q "Type 'REVERSE' to confirm" "$INSTALLER"; then
    pass "Double confirmation for reverse operation"
else
    fail "No double confirmation for reverse"
fi
echo ""

# ----------------------------------------------------------------
# Test 9: Wayland + KDE 6.6 configuration
# ----------------------------------------------------------------
echo "[TEST 9] Wayland + KDE 6.6 configuration"
if grep -q 'ELECTRON_OZONE_PLATFORM_HINT' "$INSTALLER"; then
    pass "Electron Ozone platform hint configured"
else
    fail "Missing Electron Ozone platform configuration"
fi
if grep -q 'WaylandWindowDecorations' "$INSTALLER"; then
    pass "Wayland window decorations enabled"
else
    fail "Missing WaylandWindowDecorations feature flag"
fi
if grep -q 'electron-flags.conf' "$INSTALLER"; then
    pass "electron-flags.conf configuration present"
else
    fail "Missing electron-flags.conf setup"
fi
if grep -q 'electron25-flags.conf' "$INSTALLER"; then
    pass "electron25-flags.conf configuration present"
else
    fail "Missing electron25-flags.conf setup"
fi
if grep -qE 'kde|plasma' "$INSTALLER"; then
    pass "KDE/Plasma detection logic present"
else
    fail "No KDE/Plasma detection"
fi
if grep -q 'enable-wayland-ime' "$INSTALLER"; then
    pass "Wayland IME support configured"
else
    fail "Missing Wayland IME configuration"
fi
echo ""

# ----------------------------------------------------------------
# Test 10: Does not run as root
# ----------------------------------------------------------------
echo "[TEST 10] Root prevention check"
if grep -q 'EUID.*-eq.*0' "$INSTALLER"; then
    pass "Prevents running as root"
else
    fail "No root prevention check"
fi
echo ""

# ----------------------------------------------------------------
# Test 11: Dry-run support
# ----------------------------------------------------------------
echo "[TEST 11] Dry-run mode"
if grep -q '\-\-dry-run' "$INSTALLER"; then
    pass "--dry-run flag supported"
else
    fail "No --dry-run flag"
fi
if grep -q 'DRY_RUN' "$INSTALLER"; then
    pass "DRY_RUN variable used throughout"
else
    fail "No DRY_RUN variable"
fi
echo ""

# ----------------------------------------------------------------
# Test 12: Verification phase
# ----------------------------------------------------------------
echo "[TEST 12] Post-install verification"
if grep -q 'phase_verify_and_cleanup' "$INSTALLER"; then
    pass "Verification phase present"
else
    fail "No verification phase"
fi
if grep -q 'Verifying application structure' "$INSTALLER"; then
    pass "Application structure verification present"
else
    fail "No application structure verification"
fi
echo ""

# ----------------------------------------------------------------
# Test 13: Help flag
# ----------------------------------------------------------------
echo "[TEST 13] Help flag"
if grep -q '\-\-help' "$INSTALLER"; then
    pass "--help flag supported"
else
    fail "No --help flag"
fi
echo ""

# ----------------------------------------------------------------
# Test 14: Cleanup of temporary files
# ----------------------------------------------------------------
echo "[TEST 14] Temporary file cleanup"
if grep -q 'Cleaning up temporary files' "$INSTALLER"; then
    pass "Temporary file cleanup present"
else
    fail "No temporary file cleanup"
fi
echo ""

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
echo ""
echo "==================================="
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
else
    echo -e "${RED}❌ $FAILURES TEST(S) FAILED${NC}"
fi
echo "==================================="

exit $FAILURES
