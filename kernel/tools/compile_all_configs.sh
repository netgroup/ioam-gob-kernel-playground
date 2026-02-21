#!/bin/bash

# Enforce strict mode: exit on error, undefined vars, or pipe failures
set -euo pipefail

# Kernel source directory (current directory)
KERNEL_DIR="../linux/"
SCRIPTS_CONFIG="scripts/config"

BASE_CONFIG="config-BPF_N-BTF_N-LWT_N-GOB_N.config"

ABS_CONFIG_PATH="$(readlink -f "$BASE_CONFIG")"
ABS_SCRIPT_CONFIG="$(readlink -f "$KERNEL_DIR/$SCRIPTS_CONFIG")"

# Detect number of processing units for compilation
# Default to nproc, fallback to 1 if nproc is missing
CORES=$(nproc 2>/dev/null || echo 1)

# Check for required files
if [[ ! -f "$ABS_CONFIG_PATH" ]]; then
    echo "Error: Base config $ABS_CONFIG_PATH not found."
    exit 1
fi

if [[ ! -x "$ABS_SCRIPT_CONFIG" ]]; then
    echo "Error: scripts/config not found or not executable."
    exit 1
fi

# Function to set a configuration option in .config
set_config() {
    local config_name="$1"
    local value="$2"
    # Convert 'Y' or 'y' to lower case for comparison
    if [[ "${value,,}" == "y" ]]; then
        $SCRIPTS_CONFIG --enable "$config_name"
    else
        $SCRIPTS_CONFIG --disable "$config_name"
    fi
}

# Define valid combinations
declare -a combinations=(
    "N N N N"
    "Y Y N N"
    "Y Y Y N"
    "Y Y N Y"
    "Y Y Y Y"
)

pushd "$KERNEL_DIR" > /dev/null

for combo in "${combinations[@]}"; do
    echo "----------------------------------------------------"
    echo "Processing combination: $combo"

    # Reset configuration
    cp "$ABS_CONFIG_PATH" .config

    # Read combination into variables
    read -r BPF_SYSCALL DEBUG_INFO_BTF IPV6_IOAM6_LWTUNNEL IPV6_IOAM6_GOB <<< "$combo"

    # --- Logic Block ---

    # 1. BPF and BTF
    if [[ "$BPF_SYSCALL" == "Y" ]]; then
        set_config CONFIG_BPF_SYSCALL y
        set_config CONFIG_DEBUG_INFO_BTF y
    else
        set_config CONFIG_BPF_SYSCALL n
        set_config CONFIG_DEBUG_INFO_BTF n
    fi

    # 2. IOAM6 Tunnel
    set_config CONFIG_IPV6_IOAM6_LWTUNNEL "$IPV6_IOAM6_LWTUNNEL"

    # 3. IOAM6 GOB (Dependent on BPF)
    if [[ "$BPF_SYSCALL" == "Y" ]] && [[ "$IPV6_IOAM6_GOB" == "Y" ]]; then
        set_config CONFIG_IPV6_IOAM6_GOB y
    else
        set_config CONFIG_IPV6_IOAM6_GOB n
    fi

    # --- Sanitization Block ---

    # Run olddefconfig FIRST to resolve dependencies and fix the .config
    make olddefconfig > /dev/null

    # Define name based on the actual requested logic
    CONFIG_NAME="config-BPF_${BPF_SYSCALL}-BTF_${DEBUG_INFO_BTF}-LWT_${IPV6_IOAM6_LWTUNNEL}-GOB_${IPV6_IOAM6_GOB}"

    # Save the sanitized config (The one actually used for build)
    cp .config "$CONFIG_NAME"
    echo "Generated and sanitized: $CONFIG_NAME"

    # --- Compilation Block ---

    LOG_FILE="compile-${CONFIG_NAME}.log"
    echo "Compiling... (Log: $LOG_FILE)"

    # We use 'set +e' specifically here because we want to handle the error manually
    set +e

    # Clean previous build artifacts (optional: make mrproper is safer but slower)
    make -j"$CORES" clean > /dev/null 2>&1

    # Compile
    # using 'time' requires a block or subshell in bash to pipe correctly
    { time make -j"$CORES" C=1 W=1 2>&1; } | tee "$LOG_FILE"
    BUILD_STATUS=${PIPESTATUS[0]} # Capture exit code of 'make', not 'tee'

    set -e # Re-enable strict mode

    if [ $BUILD_STATUS -ne 0 ]; then
        echo "!!!! BUILD FAILED for $CONFIG_NAME !!!!"
        echo "Check $LOG_FILE for details."
        exit 1
    else
        echo "Build SUCCESS: $CONFIG_NAME"
    fi
done

popd > /dev/null

echo "========================================================"
echo "All configurations generated and compiled successfully."
