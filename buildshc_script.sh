#!/bin/bash

# X-Seti - July26 2025 - AutoPak Build Script - Version: 1.0
# this belongs in root /buildshc.sh

# Build AutoPak binary for current platform
# Note: shc only compiles for the current architecture/OS

SCRIPT_NAME="autopak.sh"
OUTPUT_NAME="autopak"

# Detect current platform
PLATFORM=$(uname -m)
OS=$(uname -s)

case "$OS" in
    Linux)
        case "$PLATFORM" in
            x86_64) SUFFIX="linux-x86_64" ;;
            aarch64|arm64) SUFFIX="linux-arm64" ;;
            armv7l) SUFFIX="linux-armv7" ;;
            i686|i386) SUFFIX="linux-i386" ;;
            *) SUFFIX="linux-${PLATFORM}" ;;
        esac
        ;;
    Darwin)
        case "$PLATFORM" in
            x86_64) SUFFIX="macos-intel" ;;
            arm64) SUFFIX="macos-apple" ;;
            *) SUFFIX="macos-${PLATFORM}" ;;
        esac
        ;;
    MINGW*|CYGWIN*|MSYS*)
        SUFFIX="windows-${PLATFORM}"
        OUTPUT_NAME="autopak.exe"
        ;;
    FreeBSD)
        SUFFIX="freebsd-${PLATFORM}"
        ;;
    OpenBSD)
        SUFFIX="openbsd-${PLATFORM}"
        ;;
    NetBSD)
        SUFFIX="netbsd-${PLATFORM}"
        ;;
    *)
        SUFFIX="${OS,,}-${PLATFORM}"
        ;;
esac

echo "🔨 Building AutoPak for: $OS $PLATFORM"
echo "📦 Output: ${OUTPUT_NAME}-${SUFFIX}"

# Check if shc is available
if ! command -v shc &> /dev/null; then
    echo "❌ shc not found. Install with:"
    case "$OS" in
        Linux)
            if command -v apt &> /dev/null; then
                echo "  sudo apt install shc"
            elif command -v yum &> /dev/null; then
                echo "  sudo yum install shc"
            elif command -v pacman &> /dev/null; then
                echo "  sudo pacman -S shc"
            else
                echo "  Install shc using your package manager"
            fi
            ;;
        Darwin)
            echo "  brew install shc"
            ;;
        *)
            echo "  Install shc for your platform"
            ;;
    esac
    exit 1
fi

# Check if source script exists
if [[ ! -f "$SCRIPT_NAME" ]]; then
    echo "❌ Source script not found: $SCRIPT_NAME"
    exit 1
fi

# Create build directory
mkdir -p build

# Compile with shc
echo "🔧 Compiling with shc..."
if shc -f "$SCRIPT_NAME" -o "build/${OUTPUT_NAME}-${SUFFIX}"; then
    echo "✅ Compilation successful!"
    
    # Clean up generated files
    if [[ -f "${SCRIPT_NAME}.x.c" ]]; then
        mv "${SCRIPT_NAME}.x.c" "build/autopak-${SUFFIX}.c"
        echo "📝 C source moved to: build/autopak-${SUFFIX}.c"
    fi
    
    # Make executable
    chmod +x "build/${OUTPUT_NAME}-${SUFFIX}"
    
    # Show file info
    echo "📊 Binary info:"
    ls -lh "build/${OUTPUT_NAME}-${SUFFIX}"
    file "build/${OUTPUT_NAME}-${SUFFIX}"
    
    # Optionally install to ~/bin/
    read -p "Install to ~/bin/autopak? (y/N): " install_choice
    if [[ "$install_choice" =~ ^[Yy]$ ]]; then
        mkdir -p ~/bin
        cp "build/${OUTPUT_NAME}-${SUFFIX}" ~/bin/autopak
        chmod +x ~/bin/autopak
        echo "✅ Installed to: ~/bin/autopak"
        
        # Check if ~/bin is in PATH
        if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
            echo "⚠️  Add ~/bin to your PATH with:"
            echo "   echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.bashrc"
        fi
    fi
    
    echo
    echo "🎉 Build complete!"
    echo "📁 Binary location: build/${OUTPUT_NAME}-${SUFFIX}"
    
else
    echo "❌ Compilation failed!"
    exit 1
fi

# Show available binaries
echo
echo "📦 Available binaries:"
ls -la build/autopak-* 2>/dev/null || echo "   None yet"

echo
echo "💡 To build for other platforms:"
echo "   - Run this script on each target platform"
echo "   - Or use Docker/VM for cross-platform builds"