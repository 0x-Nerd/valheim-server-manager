
#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper function
function prompt_continue() {
    echo -n -e "\nPress Enter to continue..."
    read
}

# Start
clear
echo -e "${CYAN}========== Raspberry Pi Valheim Setup ==========${NC}"

# Check Architecture
ARCH=$(uname -m)

if [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]]; then
    echo -e "${RED}ERROR: This setup is intended for ARM-based systems like Raspberry Pi.${NC}"
    prompt_continue
    exit 1
fi

# Warn about reboot during page size fix
echo -e "${YELLOW}⚡ WARNING: This setup will require a reboot to switch your Raspberry Pi to 4K page size.${NC}"
echo -e "You will need to manually reconnect and re-run the Valheim Manager script after reboot to continue."
echo -n -e "\nProceed with setup and reboot when needed? (y/n): "
read proceed

if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
    echo -e "\n${CYAN}Setup canceled by user.${NC}"
    prompt_continue
    exit 0
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
fi

# Install Dependencies
echo -e "\n${CYAN}Installing required build dependencies...${NC}"
sudo apt update
sudo apt install -y cmake git build-essential

# Install Box86
if [[ ! -d "$HOME/box86" ]]; then
    echo -e "\n${CYAN}Cloning Box86 repository...${NC}"
    git clone https://github.com/ptitSeb/box86.git ~/box86
fi

echo -e "\n${CYAN}Building and installing Box86...${NC}"
cd ~/box86
mkdir -p build
cd build
cmake ..
make -j$(nproc)
sudo make install

# Install Box64
if [[ ! -d "$HOME/box64" ]]; then
    echo -e "\n${CYAN}Cloning Box64 repository...${NC}"
    git clone https://github.com/ptitSeb/box64.git ~/box64
fi

echo -e "\n${CYAN}Building and installing Box64...${NC}"
cd ~/box64
mkdir -p build
cd build
cmake ..
make -j$(nproc)
sudo make install

# Final Checks
if command -v box86 >/dev/null && command -v box64 >/dev/null; then
    echo -e "\n${GREEN}✅ Box86 and Box64 installed successfully.${NC}"
else
    echo -e "\n${RED}❌ Box86/Box64 installation failed. Please check manually.${NC}"
    prompt_continue
    exit 1
fi

# Set Flag File
touch "${VALHEIM_DIR}/.rpi_ready"

echo -e "\n${GREEN}✅ Raspberry Pi environment setup complete!${NC}"
echo -e "${CYAN}You can now proceed with SteamCMD and Valheim server installation.${NC}"

prompt_continue
exit 0
