#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

LOGFILE="/tmp/rpi_install.log"

# Helper function
function prompt_continue() {
    echo -n -e "\nPress Enter to continue..."
    read
}

clear
echo -e "${CYAN}========== Raspberry Pi Valheim Setup ==========${NC}"

# Check Architecture
ARCH=$(uname -m)

if [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]]; then
    echo -e "${RED}ERROR: This setup is intended for ARM-based Raspberry Pi systems.${NC}"
    prompt_continue
    exit 1
fi

# Check Page Size
PAGE_SIZE=$(getconf PAGE_SIZE)

if [[ "$PAGE_SIZE" -eq 16384 ]]; then
    echo -e "\n${YELLOW}16K memory page size detected. This must be changed to 4K for Box86/Box64 to work properly.${NC}"
    echo -e "${CYAN}Modifying /boot/firmware/config.txt to force 4K kernel...${NC}"

    if ! grep -q "^kernel=kernel8.img" /boot/firmware/config.txt; then
        sudo sed -i '1ikernel=kernel8.img' /boot/firmware/config.txt
        echo -e "${GREEN}✅ Config updated to boot 4K kernel.${NC}"
    else
        echo -e "${GREEN}✅ Config already set to boot 4K kernel.${NC}"
    fi

    echo -e "\n${YELLOW}⚡ System needs to reboot now to apply the 4K page size.${NC}"
    echo -n -e "Reboot now? (y/n): "
    read reboot_choice

    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        sudo reboot
    else
        echo -e "\n${RED}⚡ Please reboot manually before continuing.${NC}"
        prompt_continue
        exit 0
    fi
else
    echo -e "\n${GREEN}✅ 4K page size already detected. Continuing setup.${NC}"
fi

# Update packages
echo -e "\n${CYAN}Updating package lists and upgrading...${NC}"
sudo apt update >> "${LOGFILE}" 2>&1
sudo apt upgrade -y >> "${LOGFILE}" 2>&1

# Install build essentials
echo -e "\n${CYAN}Installing required build tools...${NC}"
sudo apt install -y git build-essential cmake >> "${LOGFILE}" 2>&1

# Clone Box86
if [[ ! -d "$HOME/box86" ]]; then
    echo -e "\n${CYAN}Cloning Box86 repository...${NC}"
    git clone https://github.com/ptitSeb/box86 ~/box86 >> "${LOGFILE}" 2>&1
fi

# Add 32-bit architecture support
echo -e "\n${CYAN}Adding ARMHF (32-bit) architecture support...${NC}"
sudo dpkg --add-architecture armhf >> "${LOGFILE}" 2>&1
sudo apt update >> "${LOGFILE}" 2>&1
sudo apt install -y gcc-arm-linux-gnueabihf libc6:armhf >> "${LOGFILE}" 2>&1

# Build Box86
echo -e "\n${CYAN}Building Box86...${NC}"
cd ~/box86
mkdir -p build
cd build
cmake .. -DRPI4ARM64=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo >> "${LOGFILE}" 2>&1
make -j$(nproc) >> "${LOGFILE}" 2>&1
sudo make install >> "${LOGFILE}" 2>&1

# Restart systemd-binfmt
echo -e "\n${CYAN}Restarting systemd-binfmt service after Box86 install...${NC}"
sudo systemctl restart systemd-binfmt

# Clone Box64
if [[ ! -d "$HOME/box64" ]]; then
    echo -e "\n${CYAN}Cloning Box64 repository...${NC}"
    git clone https://github.com/ptitSeb/box64 ~/box64 >> "${LOGFILE}" 2>&1
fi

# Build Box64
echo -e "\n${CYAN}Building Box64...${NC}"
cd ~/box64
mkdir -p build
cd build
cmake .. -DRPI4ARM64=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo >> "${LOGFILE}" 2>&1
make -j$(nproc) >> "${LOGFILE}" 2>&1
sudo make install >> "${LOGFILE}" 2>&1

# Restart systemd-binfmt again
echo -e "\n${CYAN}Restarting systemd-binfmt service after Box64 install...${NC}"
sudo systemctl restart systemd-binfmt

# Final Checks
if command -v box86 >/dev/null && command -v box64 >/dev/null; then
    echo -e "\n${GREEN}✅ Box86 and Box64 installed successfully!${NC}"
else
    echo -e "\n${RED}❌ Box86/Box64 installation failed! Check ${LOGFILE} for details.${NC}"
    tail -n 20 "${LOGFILE}"
    prompt_continue
    exit 1
fi

# Set Ready Flag (inside scripts/ directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
touch "${SCRIPT_DIR}/.rpi_ready"

echo -e "\n${GREEN}✅ Raspberry Pi Valheim environment setup complete!${NC}"
echo -e "${CYAN}You can now proceed with SteamCMD and Valheim server installation.${NC}"

prompt_continue
exit 0
