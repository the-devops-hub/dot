#!/usr/bin/env sh
set -e

REPO="${DOT_REPO:-the-devops-hub/dot}"
BIN_DIR="${DOT_BIN_DIR:-$HOME/.local/bin}"

# ── 1. Detect OS + arch ───────────────────────────────────────────────────────

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)  os="linux" ;;
  Darwin) os="darwin" ;;
  *)
    echo "error: unsupported OS: $OS" >&2
    exit 1
    ;;
esac

case "$ARCH" in
  x86_64)          arch="amd64" ;;
  aarch64 | arm64) arch="arm64" ;;
  *)
    echo "error: unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

# ── 2. Download and extract tarball ──────────────────────────────────────────

ASSET="dot-${os}-${arch}.tar.gz"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

echo "Installing dot..."
echo "  Downloading $ASSET"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$TMP/dot.tar.gz"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP/dot.tar.gz" "$URL"
else
  echo "error: curl or wget is required" >&2
  exit 1
fi

tar -xzf "$TMP/dot.tar.gz" -C "$TMP"

# ── 3. Install binary ─────────────────────────────────────────────────────────

mkdir -p "$BIN_DIR"
install -m755 "$TMP/dot" "$BIN_DIR/dot"
echo "  Installed to $BIN_DIR/dot"

# ── 4. Shell integration (mirrors shell.zig:ensureSourced) ───────────────────

SOURCE_MARKER="# dot: source shell integration"
PATH_MARKER="# dot: add local bin to PATH"

setup_shell_integration() {
  shell_name="$1"    # bash | zsh | fish
  rc_file="$2"       # e.g. ~/.bashrc
  integ_file="$3"    # e.g. ~/.local/bin/shell-integration.bash

  # Create integration file if absent (no truncation)
  if [ ! -f "$integ_file" ]; then
    mkdir -p "$(dirname "$integ_file")"
    touch "$integ_file"
  fi

  # Write PATH export into integration file (idempotent)
  if ! grep -qF "$PATH_MARKER" "$integ_file" 2>/dev/null; then
    if [ "$shell_name" = "fish" ]; then
      # shellcheck disable=SC2016
      printf '\n%s\nset -gx PATH %s $PATH\n' "$PATH_MARKER" "$BIN_DIR" >> "$integ_file"
    else
      # shellcheck disable=SC2016
      printf '\n%s\nexport PATH="%s:$PATH"\n' "$PATH_MARKER" "$BIN_DIR" >> "$integ_file"
    fi
  fi

  # Ensure RC file sources the integration file (idempotent)
  if ! grep -qF "$SOURCE_MARKER" "$rc_file" 2>/dev/null; then
    mkdir -p "$(dirname "$rc_file")"
    printf '\n%s\nsource %s\n' "$SOURCE_MARKER" "$integ_file" >> "$rc_file"
    echo "  Updated $rc_file"
  fi
}

# Detect active shell and wire up the matching RC
SHELL_NAME="$(basename "${SHELL:-sh}")"

case "$SHELL_NAME" in
  fish)
    RC_FILE="$HOME/.config/fish/config.fish"
    INTEG_FILE="$BIN_DIR/shell-integration.fish"
    setup_shell_integration fish "$RC_FILE" "$INTEG_FILE"
    ;;
  zsh)
    RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
    INTEG_FILE="$BIN_DIR/shell-integration.zsh"
    setup_shell_integration zsh "$RC_FILE" "$INTEG_FILE"
    ;;
  bash)
    RC_FILE="$HOME/.bashrc"
    INTEG_FILE="$BIN_DIR/shell-integration.bash"
    setup_shell_integration bash "$RC_FILE" "$INTEG_FILE"
    ;;
  *)
    echo "  Note: shell '$SHELL_NAME' not recognised — skipping RC integration"
    ;;
esac

# Export PATH for the current session so dot doctor runs immediately
export PATH="$BIN_DIR:$PATH"

# ── 5. Run dot doctor ─────────────────────────────────────────────────────────

echo ""
"$BIN_DIR/dot" doctor

# ── 6. Next steps ─────────────────────────────────────────────────────────────

echo ""
echo "Done. Restart your shell (or run: source $RC_FILE) then try:"
echo "  dot list                    # see available tools"
echo "  dot install --group k8s     # install all k8s tools"
