#!/usr/bin/env bash
# Sets up the assistant's tools in a Linux cloud container (Ubuntu 24.04), so Claude
# Code can do the panel's work directly, without KiCad's window or the panel.
#
#   bash cloud/setup.sh            # install what's missing (safe to rerun; fast once done)
#   bash cloud/setup.sh --check    # only report what's installed
#
# Mirrors install.ps1: KiCad 10, the pinned KiCad MCP server with patches/kicad-mcp.patch,
# its Python packages, Java 25 + Freerouting 2.4.1 (checked against their SHA-256), the
# METU Power Lab library clone and KiCad's METUPOWERLAB_* paths. Everything except the
# KiCad packages lives under $POWERLAB_HOME. Paths are written to $POWERLAB_HOME/env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POWERLAB_HOME="${POWERLAB_HOME:-$HOME/.local/share/PowerLabKiCadAssistant}"
LIBRARY_PATH="${POWERLAB_LIBRARY:-$HOME/PowerLabKiCadLibraries}"
MCP_DIR="$POWERLAB_HOME/KiCAD-MCP-Server"
MCP_REPO="https://github.com/mixelpixx/KiCAD-MCP-Server.git"
LIBRARY_REPO="https://github.com/odtu/PowerLabKiCadLibraries.git"
# Same pin as install.ps1 ($McpCommit); change both together.
MCP_COMMIT="$(sed -n 's/^ *\[string\]\$McpCommit = "\([0-9a-f]*\)".*/\1/p' "$ROOT/install.ps1")"
KICAD_PPA="https://ppa.launchpadcontent.net/kicad/kicad-10.0-releases/ubuntu"
KICAD_PPA_KEY="FDA854F61C4D0D9572BB95E5245D5502FAD7A805"
PY=python3.12  # Ubuntu 24.04's Python, which KiCad's pcbnew module is built for

JAVA_VERSION="25.0.4.1"
JAVA_URL="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/OpenJDK25U-jre_x64_linux_hotspot_25.0.4.1_1.tar.gz"
JAVA_SHA256="1731a34baadec5479258ea0202e4d5d865d2efeee60cb0c7d7eb056fe96ca219"
FREEROUTING_VERSION="2.4.1"
FREEROUTING_URL="https://github.com/freerouting/freerouting/releases/download/v2.4.1/freerouting-2.4.1.jar"
FREEROUTING_SHA256="251101c3eeac22d7e7dfcf6796603279e5d1000283eb82d8f093780f7afc6aa9"  # as install.ps1

JAVA_HOME_DIR="$POWERLAB_HOME/java-$JAVA_VERSION"
FREEROUTING_JAR="$POWERLAB_HOME/freerouting/freerouting-$FREEROUTING_VERSION.jar"
KICAD_CONFIG="$HOME/.config/kicad/10.0"

say() { printf '\033[36m%s\033[0m\n' "$*"; }
ok() { printf '  OK  %s\n' "$*"; }
warn() { printf '  !   %s\n' "$*" >&2; }
fail() { printf '  X   %s\n' "$*" >&2; exit 1; }
quiet() { "$@" >/dev/null 2>&1; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

if [ "${1:-}" = "--check" ]; then
    command -v kicad-cli >/dev/null && ok "KiCad $(kicad-cli version 2>/dev/null)" || warn "KiCad 10 missing"
    [ -f "$MCP_DIR/dist/index.js" ] && ok "MCP server at $MCP_DIR" || warn "MCP server missing"
    [ -x "$JAVA_HOME_DIR/bin/java" ] && ok "Java $JAVA_VERSION" || warn "Java missing"
    [ -f "$FREEROUTING_JAR" ] && ok "Freerouting $FREEROUTING_VERSION" || warn "Freerouting missing"
    [ -d "$LIBRARY_PATH/.git" ] && ok "Library at $LIBRARY_PATH" || warn "Library clone missing"
    exit 0
fi

# Several sessions (the SessionStart hook and the MCP wrapper) may start this at once.
mkdir -p "$POWERLAB_HOME"
exec 9>"$POWERLAB_HOME/setup.lock"
flock 9

# Download $1 to $3, refusing it unless its SHA-256 is $2.
get_verified() {
    curl -fsSL --retry 3 -o "$3.download" "$1"
    if [ "$(sha256sum "$3.download" | cut -d' ' -f1)" != "$2" ]; then
        rm -f "$3.download"; fail "$(basename "$1") failed its checksum check; not installed."
    fi
    mv "$3.download" "$3"
}

# ---- 1. KiCad 10 -----------------------------------------------------------
say "1. KiCad 10"
if ! command -v kicad-cli >/dev/null || ! kicad-cli version 2>/dev/null | grep -q '^10\.'; then
    # add-apt-repository needs python3-apt, which this image's python3 lacks: add the PPA by hand.
    $SUDO mkdir -p /etc/apt/keyrings
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$KICAD_PPA_KEY" \
        | gpg --dearmor | $SUDO tee /etc/apt/keyrings/kicad-10.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/kicad-10.gpg] $KICAD_PPA noble main" \
        | $SUDO tee /etc/apt/sources.list.d/kicad-10.list >/dev/null
    $SUDO apt-get update -qq
    # Symbol and footprint libraries, but not the multi-GB 3D model package.
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends \
        kicad kicad-symbols kicad-footprints >/dev/null
fi
ok "KiCad $(kicad-cli version 2>/dev/null)"
command -v node >/dev/null || fail "Node.js 18+ is needed for the MCP server."

# ---- 2. KiCad MCP server ---------------------------------------------------
say "2. KiCad MCP server ($MCP_COMMIT + patches/kicad-mcp.patch)"
PATCH="$ROOT/patches/kicad-mcp.patch"
[ -d "$MCP_DIR/.git" ] || git clone -q "$MCP_REPO" "$MCP_DIR"
rebuild=0
if ! git -C "$MCP_DIR" rev-parse HEAD | grep -q "^$MCP_COMMIT"; then
    git -C "$MCP_DIR" fetch -q origin
    git -C "$MCP_DIR" checkout -q --force "$MCP_COMMIT"
    rebuild=1
fi
if ! quiet git -C "$MCP_DIR" apply --check -R "$PATCH"; then
    # Not applied, or an older version is: start again from the pinned files (as install.ps1).
    git -C "$MCP_DIR" checkout -q --force "$MCP_COMMIT"
    git -C "$MCP_DIR" clean -fdq -- python src
    git -C "$MCP_DIR" apply --whitespace=nowarn "$PATCH"
    rebuild=1
fi
if [ $rebuild = 1 ] || [ ! -f "$MCP_DIR/dist/index.js" ]; then
    (cd "$MCP_DIR" && npm ci --no-audit --no-fund --loglevel=error >/dev/null && npm run build --silent >/dev/null)
fi
ok "MCP server built"
if ! quiet $PY -c "import pcbnew, pymupdf, skip, kipy, sexpdata"; then
    $PY -m pip install --quiet --break-system-packages --ignore-installed -r "$MCP_DIR/requirements.txt" 2>&1 \
        | grep -v -e '^WARNING: Running pip as' >&2 || true
fi
ok "Python packages for $PY"

# ---- 3. Java 25 + Freerouting (powerlab-autoroute) -------------------------
say "3. Java $JAVA_VERSION and Freerouting $FREEROUTING_VERSION"
if [ ! -x "$JAVA_HOME_DIR/bin/java" ]; then
    tarball="$POWERLAB_HOME/java-$JAVA_VERSION.tar.gz"
    get_verified "$JAVA_URL" "$JAVA_SHA256" "$tarball"
    rm -rf "$JAVA_HOME_DIR"; mkdir -p "$JAVA_HOME_DIR"
    tar -xzf "$tarball" -C "$JAVA_HOME_DIR" --strip-components=1
    rm -f "$tarball"
fi
if [ ! -f "$FREEROUTING_JAR" ]; then
    mkdir -p "$(dirname "$FREEROUTING_JAR")"
    get_verified "$FREEROUTING_URL" "$FREEROUTING_SHA256" "$FREEROUTING_JAR"
fi
ok "$("$JAVA_HOME_DIR/bin/java" -version 2>&1 | grep -m1 version)"

# ---- 4. METU Power Lab library ---------------------------------------------
say "4. METU Power Lab library"
if [ -d "$LIBRARY_PATH/.git" ]; then
    git -C "$LIBRARY_PATH" fetch -q origin || warn "Couldn't fetch library updates."
    ok "Using the clone at $LIBRARY_PATH"
elif git clone -q "$LIBRARY_REPO" "$LIBRARY_PATH"; then
    ok "Cloned to $LIBRARY_PATH"
else
    warn "Couldn't clone $LIBRARY_REPO; library work won't be possible."
fi

# ---- 5. KiCad settings -----------------------------------------------------
say "5. KiCad settings"
mkdir -p "$KICAD_CONFIG"
[ -f "$KICAD_CONFIG/kicad_common.json" ] || quiet $PY -c "import pcbnew" || true  # KiCad writes its defaults
[ -f "$KICAD_CONFIG/kicad_common.json" ] || echo '{}' > "$KICAD_CONFIG/kicad_common.json"
for table in sym-lib-table fp-lib-table; do  # KiCad's stock libraries, as a first start would copy them
    [ -f "$KICAD_CONFIG/$table" ] || cp "/usr/share/kicad/template/$table" "$KICAD_CONFIG/$table"
done
if [ -d "$LIBRARY_PATH/symbols" ]; then
    # configure_kicad.py reads KiCad's folder from %APPDATA%\kicad\10.0; on Linux that's ~/.config.
    APPDATA="$HOME/.config" $PY "$ROOT/tools/configure_kicad.py" --library "$LIBRARY_PATH" | sed 's/^/  /'
fi

# ---- Paths for the MCP wrapper and Claude ----------------------------------
cat > "$POWERLAB_HOME/env" <<EOF
export POWERLAB_HOME="$POWERLAB_HOME"
export POWERLAB_LIBRARY="$LIBRARY_PATH"
export KICAD_MCP_DIR="$MCP_DIR"
export KICAD_PYTHON="$(command -v $PY)"
export JAVA_HOME="$JAVA_HOME_DIR"
export FREEROUTING_JAR="$FREEROUTING_JAR"
export PATH="$JAVA_HOME_DIR/bin:\$PATH"
EOF
touch "$POWERLAB_HOME/ready"
ok "Done. Paths in $POWERLAB_HOME/env"
