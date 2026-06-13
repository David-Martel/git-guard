#!/bin/sh
#
# Cross-platform reserved filename cleanup script
# Removes Windows reserved filenames (nul, con, prn, aux, com1-9, lpt1-9) from git repositories
#
# Works in: Git Bash, WSL, Linux, macOS
# Uses NukeNul.exe on Windows for comprehensive cleanup
# Falls back to shell-based cleanup on non-Windows systems
#
# MANDATORY: This hook runs as part of pre-commit to ensure no reserved
# filenames are committed to the repository.
#
# `local` is used intentionally: every shell this runs on (bash, dash, BusyBox
# ash, Git-Bash) supports it. SC3043 (POSIX undefined) is suppressed file-wide.
# shellcheck disable=SC3043

set -e  # Exit on error - this is MANDATORY for pre-commit

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

# Optional native NukeNul.exe accelerator (Windows). Point $NUKENUL_BIN at it to
# use the fast native cleanup; otherwise the portable POSIX shell fallback below
# handles every platform. No machine-specific path is hardcoded (public-safe):
# the pure-shell path is the universal default.
NUKENUL_WIN="${NUKENUL_BIN:-}"
NUKENUL_UNIX="${NUKENUL_BIN:-}"

FIND_BIN="find"
if [ -x /usr/bin/find ]; then
    FIND_BIN=/usr/bin/find
elif command -v gfind >/dev/null 2>&1; then
    FIND_BIN=$(command -v gfind)
elif command -v find >/dev/null 2>&1; then
    FIND_BIN=$(command -v find)
fi

# Function to check if running on Windows or WSL with access to Windows binaries
detect_windows_env() {
    # Check for native Windows (Git Bash, MSYS2, Cygwin)
    if [ -f "$NUKENUL_WIN" ]; then
        echo "windows"
        return 0
    fi
    # Check for WSL with access to Windows filesystem
    if [ -f "$NUKENUL_UNIX" ]; then
        echo "wsl"
        return 0
    fi
    echo "unix"
    return 0
}

# Function to convert path for Windows execution
convert_path_for_windows() {
    local path="$1"
    local env="$2"

    case "$env" in
        windows)
            # Git Bash: convert /c/path to C:/path
            echo "$path" | sed 's|^/\([a-zA-Z]\)/|\1:/|'
            ;;
        wsl)
            # WSL: convert /home/user to /mnt/c/... or keep as-is for Windows paths
            if echo "$path" | grep -q "^/mnt/"; then
                # Already a Windows path in WSL format, convert to Windows format
                echo "$path" | sed 's|^/mnt/\([a-zA-Z]\)/|\1:/|'
            else
                # Linux path, use wslpath if available
                if command -v wslpath >/dev/null 2>&1; then
                    wslpath -w "$path" 2>/dev/null || echo "$path"
                else
                    echo "$path"
                fi
            fi
            ;;
        *)
            echo "$path"
            ;;
    esac
}

# Function to run NukeNul.exe
run_nukenul() {
    local env="$1"
    local target_path="$2"

    echo "Running NukeNul.exe for comprehensive reserved filename cleanup..."

    case "$env" in
        windows)
            "$NUKENUL_WIN" "$target_path"
            ;;
        wsl)
            "$NUKENUL_UNIX" "$target_path"
            ;;
    esac

    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "WARNING: NukeNul.exe returned exit code $exit_code"
    fi
    return $exit_code
}

# Function for fallback shell-based cleanup (non-Windows systems)
shell_cleanup() {
    local target="$1"
    local found_files=0

    echo "Running shell-based reserved filename cleanup..."

    # List of Windows reserved filenames (case-insensitive patterns)
    # nul, con, prn, aux, com1-9, lpt1-9
    RESERVED_PATTERNS="nul con prn aux com1 com2 com3 com4 com5 com6 com7 com8 com9 lpt1 lpt2 lpt3 lpt4 lpt5 lpt6 lpt7 lpt8 lpt9"

    for pattern in $RESERVED_PATTERNS; do
        # Find files matching the pattern (case-insensitive)
        FILES=$("$FIND_BIN" "$target" -iname "$pattern" -type f 2>/dev/null || true)
        if [ -n "$FILES" ]; then
            echo "$FILES" | while read -r file; do
                if [ -f "$file" ]; then
                    rm -f "$file" 2>/dev/null && echo "  Removed: $file"
                    found_files=1
                fi
            done
        fi

        # Also check for files with extensions (e.g., nul.txt)
        FILES_EXT=$("$FIND_BIN" "$target" -iname "${pattern}.*" -type f 2>/dev/null || true)
        if [ -n "$FILES_EXT" ]; then
            echo "$FILES_EXT" | while read -r file; do
                if [ -f "$file" ]; then
                    rm -f "$file" 2>/dev/null && echo "  Removed: $file"
                    found_files=1
                fi
            done
        fi
    done

    if [ $found_files -eq 0 ]; then
        echo "  No reserved filenames found."
    fi

    echo "Shell cleanup complete."
}

# Main execution
echo "=== Reserved Filename Cleanup (MANDATORY) ==="

ENV_TYPE=$(detect_windows_env)
echo "Detected environment: $ENV_TYPE"
echo "Repository root: $REPO_ROOT"

EXIT_CODE=0

case "$ENV_TYPE" in
    windows|wsl)
        WIN_PATH=$(convert_path_for_windows "$REPO_ROOT" "$ENV_TYPE")
        echo "Windows path: $WIN_PATH"
        run_nukenul "$ENV_TYPE" "$WIN_PATH" || EXIT_CODE=$?
        ;;
    *)
        shell_cleanup "$REPO_ROOT" || EXIT_CODE=$?
        ;;
esac

if [ $EXIT_CODE -ne 0 ]; then
    echo "WARNING: Cleanup encountered errors (exit code: $EXIT_CODE)"
fi

echo "=== Cleanup Complete ==="

# Exit with proper status
# MANDATORY mode: Set NUKENUL_MANDATORY=1 to fail pre-commit on errors
# Default: Cleanup errors are warnings only (backward compatible)
if [ "${NUKENUL_MANDATORY:-0}" = "1" ] || [ "${NUKENUL_MANDATORY:-0}" = "true" ]; then
    exit $EXIT_CODE
fi

# Non-mandatory mode: Always succeed (original behavior)
exit 0
