#!/usr/bin/env bash
# =============================================================================
# install-hooks.sh
#
# Configures Git to use the versioned hooks in .githooks/.
# Run once after cloning the repository.
#
# Usage:
#   ./install-hooks.sh
#
# What it does:
#   - Sets core.hooksPath to .githooks so Git picks up the pre-commit hook
#   - Makes all scripts in .githooks/ executable
#
# Requirements:
#   - git
#   - gitleaks    (recommended — brew install gitleaks)
#   - shellcheck  (recommended — brew install shellcheck)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/github-common.sh
source "${SCRIPT_DIR}/lib/github-common.sh"

# Override lib's print functions with [HOOKS] prefix for this script's output.
print_success() { echo -e "${GREEN}[HOOKS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[HOOKS]${NC} $1"; }
print_error()   { echo -e "${RED}[HOOKS]${NC} $1" >&2; }

# Verify we're inside a git repository
if ! git -C "$SCRIPT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not a git repository: ${SCRIPT_DIR}"
    exit 1
fi

# Point Git at the versioned hooks directory
git -C "$SCRIPT_DIR" config core.hooksPath .githooks
print_success "core.hooksPath set to .githooks"

# Ensure all hooks are executable
chmod +x "${SCRIPT_DIR}/.githooks/"*
print_success "Hook permissions set."

# Advisory: check for recommended tools
MISSING_TOOLS=()
for tool in gitleaks shellcheck; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    print_warning "Recommended tools not found: ${MISSING_TOOLS[*]}"
    print_warning "  Install with: brew install ${MISSING_TOOLS[*]}"
    print_warning "  The pre-commit hook will still run a built-in fallback for secret scanning,"
    print_warning "  but gitleaks and shellcheck provide significantly better coverage."
fi

print_success "Git hooks installed. They will run automatically on each commit."
