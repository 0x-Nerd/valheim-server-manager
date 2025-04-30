#!/bin/bash
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    # Running as root or sudo
    REAL_USER=$(logname)
else
    REAL_USER=$USER
fi

# ============================================================
# Color Codes
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ============================================================
# Helper Functions
# ============================================================

function prompt_continue() {
    read -rp "Press Enter to continue..." _
}

function prepare_directories() {
    echo -e "\n${CYAN}========== Preparing Required Directories ==========${NC}"

    mkdir -p "${VALHEIM_DIR}"
    mkdir -p "${SERVER_DIR}"
    mkdir -p "${BACKUP_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p "${WORLD_DIR}"

    echo -e "${GREEN}✅ Required directories prepared.${NC}"
}

wait_for_server_ready() {
    set +e # disable exit-on-error for grep/etc

    local world_name="$1"
    local port="$2"
    local log_file="${LOG_DIR}/${world_name}_server.log"
    local max_wait=$((18 * 60)) # 18 minutes total timeout
    local waited=0

    echo -e "\n${CYAN}Waiting for server '${world_name}' to finish startup and become joinable...${NC}"
    echo -e "${CYAN}Watching for join code or Steam server open (up to 18 min)…${NC}"

    if [[ ! -f "$log_file" ]]; then
        echo -e "${RED}❌ Log file not found: ${log_file}${NC}"
        set -e
        return 1
    fi

    while ((waited < max_wait)); do
        # 1) Cross-play join code?
        if grep -qE 'registered with join code [0-9]+' "$log_file"; then
            local last_line join_code
            last_line=$(grep -E 'registered with join code [0-9]+' "$log_file" | tail -n1)
            join_code="${last_line##* }"
            echo -e "\n${GREEN}✅ Server is ready!${NC}"
            echo -e "${CYAN}Join Code: ${GREEN}${join_code}${NC}"
            set -e
            return 0
        fi

        # 2) Steam-only “Opened Steam server”?
        if grep -q 'Opened Steam server' "$log_file"; then
            echo -e "\n${GREEN}✅ Server is ready! Steam-only mode.${NC}"
            local internal_ip external_ip
            internal_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
            external_ip=$(curl -s ifconfig.me || echo "N/A")
            echo -e "${CYAN}Join Information:"
            echo -e "📡 LAN: ${GREEN}${internal_ip}:${port}${NC}"
            echo -e "🌍 WAN: ${GREEN}${external_ip}:${port}${NC}"
            echo -e "${YELLOW}⚠️  Port forwarding required (UDP 2456–2458).${NC}"
            set -e
            return 0
        fi

        sleep 1
        ((waited++))
    done

    # 3) Timeout fallback
    echo -e "\n${YELLOW}ℹ️  No join code or Steam-server line seen in 18 min. Falling back to IP info.${NC}"
    local internal_ip external_ip
    internal_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
    external_ip=$(curl -s ifconfig.me || echo "N/A")
    echo -e "${CYAN}Join Information (fallback):"
    echo -e "📡 LAN: ${GREEN}${internal_ip}:${port}${NC}"
    echo -e "🌍 WAN: ${GREEN}${external_ip}:${port}${NC}"
    echo -e "${YELLOW}⚠️  Port forwarding required (UDP 2456–2458).${NC}"

    set -e
    return 0
}

# ============================================================
# Load Configuration
# ============================================================

#CONFIG_FILE location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.conf"

if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
else
    echo "ERROR: Configuration file not found at ${CONFIG_FILE}."
    read -rp "Press Enter to continue anyway (functions may be broken)..." _
fi

# ===== Prepare Directories =====
prepare_directories

#Load Last Session File
SESSION_FILE="${SCRIPT_DIR}/last_session.txt"

if [[ -f "${SESSION_FILE}" ]]; then
    source "${SESSION_FILE}"
fi

# Prevent “unbound variable” under set -u
WORLD_NAME="${WORLD_NAME:-}"

# Dynamic session-built variables
LOG_FILE="${LOG_DIR}/${WORLD_NAME}_server_start.log"

# ============================================================
# Other Helper Functions
# ============================================================

# Raspberry Pi auto-check
ARCH=$(uname -m)

if [[ "$ARCH" == "aarch64" || "$ARCH" == "armv7l" ]]; then
    if [[ ! -f "${SCRIPT_DIR}/.rpi_ready" ]]; then
        echo -e "${YELLOW}⚡ ARM-based system detected (likely Raspberry Pi).${NC}"
        echo -e "${YELLOW}Running Raspberry Pi setup helper script...${NC}\n"
        bash "${RPI_SETUP_SCRIPT}"
        exec "$0"
        exit
    fi
fi

function wait_for_service_start() {
    local service_name="$1"
    local retries=5
    local wait_time=1

    if systemctl is-active --quiet "$service_name"; then
        echo -e "${GREEN}✅ Service '${service_name}' is now active.${NC}"
        return
    fi

    echo -e "${BLUE}Waiting for service '${service_name}' to become active...${NC}"

    for ((i = 1; i <= retries; i++)); do
        if systemctl is-active --quiet "$service_name"; then
            echo -e "${GREEN}✅ Service '${service_name}' is now active.${NC}"
            return
        fi
        sleep $wait_time
    done

    echo -e "${RED}⚠️ Service '${service_name}' did not become active after ${retries} seconds. You may want to check status manually.${NC}"
}

function wait_for_service_stop() {
    local service_name="$1"
    local retries=5
    local wait_time=1

    if ! systemctl is-active --quiet "$service_name"; then
        echo -e "${GREEN}✅ Service '${service_name}' is already fully stopped.${NC}"
        return
    fi

    echo -e "${BLUE}Waiting for service '${service_name}' to fully stop...${NC}"

    for ((i = 1; i <= retries; i++)); do
        if ! systemctl is-active --quiet "$service_name"; then
            echo -e "${GREEN}✅ Service '${service_name}' is now fully stopped.${NC}"
            return
        fi
        sleep $wait_time
    done

    echo -e "${YELLOW}⚠️ Service '${service_name}' is still running after ${retries} seconds. You may want to check manually.${NC}"
}

function wait_for_service_status() {
    local service_name="$1"
    local retries=5
    local wait_time=1

    for ((i = 1; i <= retries; i++)); do
        if systemctl list-unit-files --type=service | grep -q "$service_name"; then
            return 0
        fi
        sleep $wait_time
    done

    return 1
}

# ============================================================
# World Management Functions
# ============================================================

function list_worlds() {
    echo -e "${CYAN}========== Available Worlds ==========${NC}"
    local found_worlds=false

    for file in "${WORLD_DIR}"/*.db; do
        filename=$(basename "${file}")

        # Ignore backup-like files
        if [[ "$filename" =~ [Bb]ackup || "$filename" =~ [Bb]ak || "$filename" =~ [Cc]opy ]]; then
            continue
        fi

        world_name="${filename%.db}"

        # Determine if world is running
        SERVICE_NAME="valheimserver-${world_name}.service"
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            status="(Running)"
        else
            status="(Stopped)"
        fi

        # Mark current selected world
        if [[ "$world_name" == "$WORLD_NAME" ]]; then
            echo "- ${world_name} (Current) ${status}"
        else
            echo "- ${world_name} ${status}"
        fi

        found_worlds=true
    done

    if [[ "$found_worlds" = false ]]; then
        echo "No worlds found."
    fi

    echo -e "${CYAN}=======================================${NC}"
    prompt_continue
}

function select_world() {
    echo -e "${CYAN}========== Select a World ==========${NC}"
    local worlds=()
    local count=1

    # Find all .db files in WORLD_DIR and build a list
    for file in "${WORLD_DIR}"/*.db; do
        filename=$(basename "${file}")

        # Ignore backup-like files (case-insensitive match)
        if [[ "$filename" =~ [Bb]ackup || "$filename" =~ [Bb]ak || "$filename" =~ [Cc]opy ]]; then
            continue
        fi

        world_name="${filename%.db}"
        worlds+=("$world_name")
        echo "${count}) ${world_name}"
        ((count++))
    done

    echo "${count}) Cancel and return to menu"
    echo -e "${CYAN}=====================================${NC}"

    read -rp "Choose an option: " choice

    if [[ "$choice" -ge 1 && "$choice" -lt "$count" ]]; then
        WORLD_NAME="${worlds[$((choice - 1))]}"
        echo -e "${GREEN}✅ World '${WORLD_NAME}' selected.${NC}"

        # Immediately save to last_session.txt
        echo "WORLD_NAME=${WORLD_NAME}" >"${SESSION_FILE}"
        prompt_continue
    else
        echo -e "${YELLOW}Cancelled. Returning to main menu in 5 seconds...${NC}"
        sleep 5
    fi
}

function generate_new_world() {
    echo -e "\n${CYAN}========== Generate a New Valheim World ==========${NC}"

    local existing_worlds
    existing_worlds=$(find "${WORLD_DIR}" -maxdepth 1 -name "*.db" | wc -l)

    local server_name=""
    local world_name=""
    local port=""
    local password=""
    local public=""
    local crossplay=""
    local disable_raids=""
    local crossplay_flag=""
    local modifiers_flag=""
    local public_flag=""
    local launch_flags=""
    local service_file=""
    local service_name=""
    local log_file=""

    while true; do
        echo -n "Enter Server Name (display name in Valheim server list): "
        read server_name

        if [[ -z "$server_name" ]]; then
            echo -e "${RED}Server name cannot be empty.${NC}"
            continue
        fi

        service_file="/etc/systemd/system/valheimserver-${world_name}.service"
        if [[ -f "$service_file" ]]; then
            echo -e "${RED}❌ A server config for world '${world_name}' already exists.${NC}"
        else
            break
        fi
    done

    while true; do
        echo -n "Enter new World Name (used for save files): "
        read world_name

        if [[ -z "$world_name" ]]; then
            echo -e "${RED}World name cannot be empty.${NC}"
            continue
        fi

        if [[ -f "${WORLD_DIR}/${world_name}.db" || -f "${WORLD_DIR}/${world_name}.fwl" ]]; then
            echo -e "${RED}❌ A world with the name '${world_name}' already exists.${NC}"
        else
            break
        fi
    done

    # Check for used ports
    shopt -s nullglob
    service_files=(/etc/systemd/system/valheimserver-*.service)
    shopt -u nullglob

    if ((${#service_files[@]})); then
        used_ports=$(grep -h -oP '(?<=-port )\d+' "${service_files[@]}" |
            sort -nu |
            paste -sd ', ' -)
    else
        used_ports=""
    fi

    if [[ -n "$used_ports" ]]; then
        echo -e "${YELLOW}⚠️ The following ports are already in use:${NC} ${GREEN}${used_ports}${NC}"
    else
        echo -e "${YELLOW}⚠️ No ports in use yet.${NC}"
    fi

    while true; do
        echo -n "Enter Port Number (valheim default 2456): "
        read port
        port=${port:-2456}

        if echo "$used_ports" | grep -q "^${port}$"; then
            echo -e "${RED}❌ Port ${port} is already in use. Please choose a different port.${NC}"
        else
            break
        fi
    done

    echo -n "Enter Password (5+ characters): "
    read password

    echo -n "Make server public? (y/n): "
    read public
    if [[ "$public" =~ ^[Yy]$ ]]; then
        public_flag="1"
    else
        public_flag="0"
    fi

    # Crossplay Warning
    echo -e "\n${YELLOW}⚠️ WARNING: Enabling Crossplay allows Xbox/PC players to connect, but may cause server instability and crashes.${NC}"
    echo -e "${YELLOW}If you dont not enable crossplay. Ports 2456-2458 UDP or (which ever port number you chose when creating your world) must be opened on your firewall for friends to join NOTE: PC ONLY.${NC}"
    echo -n "Enable Crossplay anyway? (y/n): "
    read crossplay
    if [[ "$crossplay" =~ ^[Yy]$ ]]; then
        crossplay_flag="-crossplay"
    fi

    echo -n "Disable monster raids? (y/n): "
    read disable_raids
    if [[ "$disable_raids" =~ ^[Yy]$ ]]; then
        modifiers_flag="-Modifiers Raids none"
    fi

    # Build launch flags (corrected savedir)
    launch_flags="-nographics -batchmode -name \"${server_name}\" -port ${port} -world \"${world_name}\" -password \"${password}\" -public ${public_flag} ${crossplay_flag} ${modifiers_flag} -savedir \"${VALHEIM_DIR}/valheim_data\""

    # Setup service
    service_name="valheimserver-${world_name}.service"
    service_file="/etc/systemd/system/${service_name}"
    log_file="${LOG_DIR}/${world_name}_server.log"

    sudo tee "${service_file}" >/dev/null <<EOF
[Unit]
Description=Valheim Dedicated Server - ${world_name}
Wants=network-online.target
After=network-online.target

[Service]
Environment=SteamAppId=892970
Environment=LD_LIBRARY_PATH=${VALHEIM_DIR}/linux64:\$LD_LIBRARY_PATH
WorkingDirectory=${VALHEIM_DIR}
ExecStart=${VALHEIM_DIR}/valheim_server.x86_64 ${launch_flags}
Restart=on-failure
RestartSec=10
KillSignal=SIGINT
User=${USER}
Group=${USER}
Type=simple
StandardOutput=append:${log_file}
StandardError=append:${log_file}
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "${service_name}"
    sudo systemctl start "${service_name}"

    # Wait for server to finish startup
    wait_for_server_ready "${world_name}" "${port}"

    echo -e "\n${GREEN}✅ World '${world_name}' created and server started successfully!${NC}"

    prompt_continue

}

function delete_world() {
    echo -e "\n${RED}⚠️  WARNING: This will permanently delete a world and all related files.${NC}"

    # Build list of valid worlds (must have both .fwl and .db, and no _backup_ in name)
    mapfile -t world_files < <(
        find "${WORLD_DIR}" -maxdepth 1 -name "*.fwl" |
            while read -r fwl_file; do
                base_name=$(basename "${fwl_file}" .fwl)
                db_file="${WORLD_DIR}/${base_name}.db"
                if [[ -f "$db_file" && "$base_name" != *_backup_* ]]; then
                    echo "$fwl_file"
                fi
            done | sort
    )

    if [[ ${#world_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No valid worlds found to delete.${NC}"
        prompt_continue
        return
    fi

    echo -e "\nAvailable Worlds:"
    for i in "${!world_files[@]}"; do
        world_name=$(basename "${world_files[$i]}" .fwl)
        echo "$((i + 1))) ${world_name}"
    done

    echo -n -e "\nEnter the number of the world to delete (or 'q' to cancel): "
    read choice

    if [[ "$choice" == [qQ] ]]; then
        echo -e "${CYAN}Deletion canceled by user.${NC}"
        prompt_continue
        return
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#world_files[@]})); then
        echo -e "${RED}Invalid selection.${NC}"
        prompt_continue
        return
    fi

    del_world=$(basename "${world_files[$((choice - 1))]}" .fwl)

    echo -e "\n${YELLOW}Are you absolutely sure you want to delete world '${del_world}' and all related files? (y/N): ${NC}"
    read confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Deletion canceled.${NC}"
        prompt_continue
        return
    fi

    # ─── Stop & disable services/timers ─────────────────────────────────────
    sudo systemctl stop "valheimserver-${del_world}.service" 2>/dev/null || true
    sudo systemctl disable "valheimserver-${del_world}.service" 2>/dev/null || true
    sudo systemctl disable "valheim_backup_${del_world}.timer" 2>/dev/null || true
    sudo systemctl disable "valheim_backup_${del_world}.service" 2>/dev/null || true

    sudo rm -f "/etc/systemd/system/valheimserver-${del_world}.service"
    sudo rm -f "/etc/systemd/system/valheim_backup_${del_world}.timer"
    sudo rm -f "/etc/systemd/system/valheim_backup_${del_world}.service"

    # ─── Delete world & backup files ────────────────────────────────────────
    rm -f "${WORLD_DIR}/${del_world}_backup_auto-"*.fwl 2>/dev/null || true
    rm -f "${WORLD_DIR}/${del_world}_backup_auto-"*.db 2>/dev/null || true
    rm -f "${WORLD_DIR}/${del_world}.fwl.old" 2>/dev/null || true
    rm -f "${WORLD_DIR}/${del_world}.db.old" 2>/dev/null || true
    rm -f "${WORLD_DIR}/${del_world}.db" "${WORLD_DIR}/${del_world}.fwl"
    rm -f "${LOG_DIR}/${del_world}_server.log"
    rm -f "${SCRIPT_DIR}/valheim_auto_backup_${del_world}.sh"
    rm -f "${BACKUP_DIR}/${del_world}_backup_"*.tar.gz 2>/dev/null || true
    rm -f "${BACKUP_DIR}/${del_world}_pre-restore_"*.tar.gz 2>/dev/null || true

    # Reload systemd so it forgets the old units
    sudo systemctl daemon-reload || true

    # ─── Clear any stored “current world” if it was this one ────────────────
    if [[ -f "$SESSION_FILE" ]]; then
        # Extract only the world name (right of the =)
        current_session=$(
            grep -E '^WORLD_NAME=' "$SESSION_FILE" | cut -d'=' -f2-
        )
        if [[ "$current_session" == "$del_world" ]]; then
            rm -f "$SESSION_FILE" # remove the file entirely
            WORLD_NAME=""         # clear in-memory
            echo -e "${YELLOW}Current world '${del_world}' was selected and has been cleared.${NC}"
        fi
    fi

    # ─── Final success message ──────────────────────────────────────────────
    echo -e "${GREEN}World '${del_world}' and all related files have been deleted successfully.${NC}"

    prompt_continue
}

# ============================================================
# Server Control Functions
# ============================================================

function start_valheim_server() {
    if [[ -z "${WORLD_NAME:-}" ]]; then
        echo -e "${RED}ERROR: No world selected. Cannot start server.${NC}"
        return
    fi

    echo -e "${BLUE}Starting Valheim Server for world: ${WORLD_NAME}${NC}"

    SERVICE_NAME="valheimserver-${WORLD_NAME}.service"

    if systemctl list-unit-files --type=service | grep -q "$SERVICE_NAME"; then
        sudo systemctl start "$SERVICE_NAME"

        #Waiting for service to start. Limit failures if checkikng status immediate after start
        wait_for_service_start "$SERVICE_NAME"
        sleep 3
    else
        echo -e "${RED}ERROR: Systemd service '$SERVICE_NAME' not found.${NC}"
        prompt_continue
    fi

}

function stop_valheim_server() {
    if [[ -z "${WORLD_NAME:-}" ]]; then
        echo -e "${RED}ERROR: No world selected. Cannot stop server.${NC}"
        return
    fi

    echo -e "${BLUE}Stopping Valheim Server for world: ${WORLD_NAME}${NC}"

    SERVICE_NAME="valheimserver-${WORLD_NAME}.service"

    if systemctl list-unit-files --type=service | grep -q "$SERVICE_NAME"; then
        sudo systemctl stop "$SERVICE_NAME"
        wait_for_service_stop "$SERVICE_NAME"
        sleep 3
    else
        echo -e "${RED}ERROR: Systemd service '$SERVICE_NAME' not found.${NC}"
        prompt_continue
    fi
}

function server_status() {
    if [[ -z "${WORLD_NAME:-}" ]]; then
        echo -e "${RED}ERROR: No world selected. Cannot check server status.${NC}"
        return
    fi

    echo -e "${BLUE}Checking Valheim Server Status for world: ${WORLD_NAME}${NC}"

    SERVICE_NAME="valheimserver-${WORLD_NAME}.service"

    if wait_for_service_status "$SERVICE_NAME"; then
        if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e "${GREEN}Valheim server '${WORLD_NAME}' is RUNNING.${NC}"

            start_time=$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp | cut -d'=' -f2)
            echo "Started at: ${start_time}"

            restart_time=$(systemctl show "$SERVICE_NAME" -p ExecMainStartTimestamp | cut -d'=' -f2)
            echo "Last restart: ${restart_time}"
        else
            echo -e "${YELLOW}Valheim server '${WORLD_NAME}' is STOPPED.${NC}"

            stop_time=$(systemctl show "$SERVICE_NAME" -p InactiveEnterTimestamp | cut -d'=' -f2)
            echo "Stopped at: ${stop_time}"

            restart_time=$(systemctl show "$SERVICE_NAME" -p ExecMainStartTimestamp | cut -d'=' -f2)
            echo "Last restart: ${restart_time}"
        fi
    else
        echo -e "${RED}ERROR: Systemd service '$SERVICE_NAME' not found after multiple checks.${NC}"
    fi
    prompt_continue
}

function view_server_info() {
    clear
    echo -e "${BLUE}========== Server Information ==========${NC}"
    echo -e "${BOLD}Hostname:${NC} $(hostname)"
    echo -e "${BOLD}Linux Version:${NC} $(uname -a)"
    echo -e "${BOLD}CPU Model:${NC} $(lscpu | grep 'Model name' | awk -F ':' '{print $2}' | xargs)"
    echo -e "${BOLD}Total Memory:${NC} $(free -h | awk '/^Mem:/ {print $2}')"
    echo -e "${BOLD}Disk Usage:${NC} $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')"
    echo -e "${BOLD}Server Uptime:${NC} $(uptime -p)"
    echo -e "${BLUE}=========================================${NC}"
    prompt_continue
}

function update_server_files() {
    clear
    echo -e "${YELLOW}${BOLD}WARNING:${NC} ${YELLOW}While updating is generally safe, it is recommended to create a backup of your world files and download them before continuing.${NC}"
    read -rp "Are you sure you want to update the server OS now? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Updating server operating system packages...${NC}"
        sleep 1

        sudo apt update && sudo apt upgrade -y
        sudo apt autoremove -y
        sudo apt autoclean

        echo
        echo -e "${GREEN}✅ Server system packages updated and cleaned successfully!${NC}"
        echo
        echo -e "${YELLOW}⚡ It is recommended to reboot the server to ensure all updates are fully applied.${NC}"
        prompt_continue
    else
        echo -e "${YELLOW}Update cancelled. Returning to main menu.${NC}"
        sleep 2
    fi
}

function reboot_server() {
    echo -e "${RED}${BOLD}WARNING: This will immediately reboot the entire server!${NC}"
    read -rp "Are you sure you want to reboot? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo reboot
    else
        echo -e "${YELLOW}Reboot cancelled. Returning to main menu.${NC}"
        sleep 2
    fi
}

# ============================================================
# Backup/Restore Functions
# ============================================================

function backup_world() {
    if [[ -z "${WORLD_NAME:-}" ]]; then
        echo -e "${RED}ERROR: No world selected. Cannot backup.${NC}"
        prompt_continue
        return
    fi

    echo -e "\n${CYAN}========== Creating Backup for World: ${WORLD_NAME} ==========${NC}"

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp=$(date +"%Y-%m-%d-%H%M")
    local backup_file="${BACKUP_DIR}/${WORLD_NAME}_backup_${timestamp}.tar.gz"

    # Create tar.gz backup (without full path structure)
    (
        cd "${WORLD_DIR}" || exit 1
        tar -czvf "${backup_file}" "${WORLD_NAME}.db" "${WORLD_NAME}.fwl"
    )

    echo -e "\n${GREEN}✅ Backup created: ${backup_file}${NC}"

    # Clean up old backups (keep last 10)
    local backup_count
    backup_count=$(ls "${BACKUP_DIR}/${WORLD_NAME}_backup_"*.tar.gz 2>/dev/null | wc -l)

    if ((backup_count > 10)); then
        local oldest_backup
        oldest_backup=$(ls "${BACKUP_DIR}/${WORLD_NAME}_backup_"*.tar.gz | head -n 1)
        echo -e "${YELLOW}⚡ Too many backups detected. Removing oldest backup: ${oldest_backup}${NC}"
        rm -f "$oldest_backup"
    fi

    prompt_continue
}

function restore_world() {
    echo -e "\n${CYAN}========== Restore a World Backup ==========${NC}"

    if [[ -z "${WORLD_NAME:-}" ]]; then
        echo -e "${RED}ERROR: No world selected. Cannot restore.${NC}"
        prompt_continue
        return
    fi

    local backups=()
    local count=1
    local batch_size=4
    local show_more=true

    mapfile -t all_backups < <(ls -t "${BACKUP_DIR}/${WORLD_NAME}_backup_"*.tar.gz 2>/dev/null)

    if [ ${#all_backups[@]} -eq 0 ]; then
        echo -e "${RED}No backups found for world '${WORLD_NAME}' in ${BACKUP_DIR}.${NC}"
        prompt_continue
        return
    fi

    while $show_more; do
        echo ""
        backups=("${all_backups[@]:0:$((count * batch_size))}")

        printf "%-4s %-25s %-12s %-8s\n" "#" "World" "Date" "Time"
        echo "------------------------------------------------------------"

        for i in "${!backups[@]}"; do
            backup_name=$(basename "${backups[$i]}")
            world_name="${backup_name%%_backup_*}"
            timestamp_full="${backup_name#*_backup_}"
            timestamp_full="${timestamp_full%.tar.gz}"

            date_part=$(echo "$timestamp_full" | cut -d'-' -f1-3 | tr '-' '/')
            time_part=$(echo "$timestamp_full" | cut -d'-' -f4)

            hour=${time_part:0:2}
            minute=${time_part:2:2}

            if ((10#$hour == 0)); then
                std_hour=12
                ampm="AM"
            elif ((10#$hour < 12)); then
                std_hour=$((10#$hour))
                ampm="AM"
            elif ((10#$hour == 12)); then
                std_hour=12
                ampm="PM"
            else
                std_hour=$((10#$hour - 12))
                ampm="PM"
            fi

            std_time="${std_hour}:${minute} ${ampm}"

            printf "%-4s %-25s %-12s %-8s\n" "$((i + 1)))" "$world_name" "$date_part" "$std_time"
        done

        if [ ${#all_backups[@]} -gt ${#backups[@]} ]; then
            echo "$((${#backups[@]} + 1))) Load more backups..."
        fi

        echo -n -e "\nEnter number to restore (or 'q' to quit): "
        read choice

        if [[ "$choice" == "q" ]]; then
            echo -e "\n${YELLOW}Restore canceled.${NC}"
            prompt_continue
            return
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#backups[@]}" ]; then
                selected_backup="${backups[$((choice - 1))]}"
                backup_name=$(basename "${selected_backup}")

                echo -e "\n${YELLOW}Selected backup:${NC} ${backup_name}"

                echo -n -e "\n${RED}Are you sure you want to overwrite the current world '${WORLD_NAME}' with this backup? (y/n): ${NC}"
                read confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo -e "\n${CYAN}Stopping Valheim server...${NC}"
                    stop_valheim_server

                    echo -e "\n${CYAN}Backing up current world before restore...${NC}"
                    timestamp=$(date +"%Y-%m-%d-%H%M")
                    pre_restore_backup="${BACKUP_DIR}/${WORLD_NAME}_pre-restore_${timestamp}.tar.gz"

                    tar -czvf "$pre_restore_backup" "${WORLD_DIR}/${WORLD_NAME}.db" "${WORLD_DIR}/${WORLD_NAME}.fwl" 2>/dev/null

                    echo -e "${GREEN}✅ Current world backed up as: ${pre_restore_backup}${NC}"

                    echo -e "\n${CYAN}Restoring backup...${NC}"
                    tar -xzvf "${selected_backup}" -C "${WORLD_DIR}"
                    echo -e "\n${CYAN}Starting Valheim server...${NC}"
                    start_valheim_server

                    echo -e "\n${GREEN}✅ World restored and server restarted successfully!${NC}"
                else
                    echo -e "\n${YELLOW}Restore canceled.${NC}"
                fi
                prompt_continue
                return
            elif [ "$choice" -eq $((${#backups[@]} + 1)) ] && [ ${#all_backups[@]} -gt ${#backups[@]} ]; then
                ((count++))
            else
                echo -e "${RED}Invalid selection.${NC}"
            fi
        else
            echo -e "${RED}Invalid input.${NC}"
        fi
    done
}

function setup_auto_backup() {
    echo -e "\n${CYAN}========== Auto-Backup Configuration ==========${NC}"

    if [[ -z "${WORLD_NAME:-}" ]]; then
        echo -e "${RED}ERROR: No world selected. Cannot configure auto-backups.${NC}"
        prompt_continue
        return
    fi

    local backup_scripts_dir="${SERVER_DIR}/BackupScripts"
    local backup_script="${backup_scripts_dir}/backup_${WORLD_NAME}.sh"
    local service_file="/etc/systemd/system/valheim_backup_${WORLD_NAME}.service"
    local timer_file="/etc/systemd/system/valheim_backup_${WORLD_NAME}.timer"
    local timer_exists=false

    # Check if timer already exists
    if systemctl list-timers --all | grep -q "valheim_backup_${WORLD_NAME}.timer"; then
        timer_exists=true
    fi

    if $timer_exists; then
        echo -e "\n${YELLOW}Auto-backup for world '${WORLD_NAME}' is already enabled.${NC}"
        echo "1) Change backup interval"
        echo "2) Cancel / Leave unchanged"
        echo -n -e "\nEnter your choice: "
        read edit_choice

        if [[ "$edit_choice" == "2" ]]; then
            echo -e "\n${CYAN}No changes made to auto-backup.${NC}"
            prompt_continue
            return
        fi

        echo -e "\n${CYAN}Proceeding to change interval for '${WORLD_NAME}'...${NC}"
        sudo systemctl disable --now "valheim_backup_${WORLD_NAME}.timer"
        sudo rm -f "$timer_file"
    fi

    # Select backup interval
    echo -e "\n${CYAN}Select Auto-Backup Interval:${NC}"
    echo "1) Every 30 minutes"
    echo -e "2) Every 1 hour ${GREEN}(Recommended)${NC}"
    echo "3) Every 3 hours"
    echo "4) Cancel / Do not enable auto-backup"
    echo -n -e "\nEnter your choice: "
    read interval_choice

    local on_calendar=""
    case "$interval_choice" in
        1)
            on_calendar="*:0/30"
            ;;
        2)
            on_calendar="hourly"
            ;;
        3)
            on_calendar="*:0/180"
            ;;
        4)
            echo -e "\n${CYAN}Canceled. No auto-backup enabled for '${WORLD_NAME}'.${NC}"
            prompt_continue
            return
            ;;
        *)
            echo -e "\n${RED}Invalid choice. Aborting auto-backup setup.${NC}"
            prompt_continue
            return
            ;;
    esac

    # Create backup script if not already existing
    if [ ! -f "$backup_script" ]; then
        echo -e "\n${CYAN}Creating dedicated backup script for '${WORLD_NAME}'...${NC}"
        tee "$backup_script" >/dev/null <<EOF
#!/bin/bash
source "/home/steam/valheim-server-manager/scripts/config.conf"

WORLD_NAME="${WORLD_NAME}"
timestamp=\$(date +"%Y-%m-%d-%H%M")
backup_file="\${BACKUP_DIR}/\${WORLD_NAME}_backup_\${timestamp}.tar.gz"

mkdir -p "\${BACKUP_DIR}"

(
    cd "\${WORLD_DIR}" || exit 1
    tar -czf "\${backup_file}" "\${WORLD_NAME}.db" "\${WORLD_NAME}.fwl"
)
EOF

        chmod +x "$backup_script"
    else
        echo -e "\n${CYAN}Backup script for '${WORLD_NAME}' already exists. Skipping script creation.${NC}"
    fi

    # Create systemd service
    echo -e "\n${CYAN}Creating backup service for '${WORLD_NAME}'...${NC}"
    sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=Valheim Auto Backup Service for ${WORLD_NAME}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=${USER}
Group=${USER}
WorkingDirectory=${SERVER_DIR}/BackupScripts/
ExecStart=${backup_script}
EOF

    # Create systemd timer
    echo -e "\n${CYAN}Creating backup timer for '${WORLD_NAME}'...${NC}"
    sudo tee "$timer_file" >/dev/null <<EOF
[Unit]
Description=Valheim Auto Backup Timer for ${WORLD_NAME}

[Timer]
OnCalendar=${on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Reload systemd and enable timer
    sudo systemctl daemon-reload
    sudo systemctl enable --now "valheim_backup_${WORLD_NAME}.timer"

    echo -e "\n${GREEN}✅ Auto-backup for '${WORLD_NAME}' has been set up successfully!${NC}"
    prompt_continue
}

function remove_auto_backup() {
    echo -e "\n${CYAN}========== Remove Auto-Backup ==========${NC}"

    if [[ -z "${WORLD_NAME:-}" ]]; then
        echo -e "${RED}ERROR: No world selected. Cannot remove auto-backup.${NC}"
        prompt_continue
        return
    fi

    local timer_file="/etc/systemd/system/valheim_backup_${WORLD_NAME}.timer"
    local service_file="/etc/systemd/system/valheim_backup_${WORLD_NAME}.service"
    local backup_script="${SERVER_DIR}/BackupScripts/backup_${WORLD_NAME}.sh"

    if [ ! -f "$timer_file" ]; then
        echo -e "${YELLOW}No auto-backup is configured for world '${WORLD_NAME}'.${NC}"
        prompt_continue
        return
    fi

    echo -e "\n${RED}Are you sure you want to disable and remove auto-backup for world '${WORLD_NAME}'? (y/n):${NC}"
    read confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "\n${CYAN}Stopping and disabling timer...${NC}"
        sudo systemctl stop "valheim_backup_${WORLD_NAME}.timer"
        sudo systemctl disable "valheim_backup_${WORLD_NAME}.timer"

        echo -e "\n${CYAN}Removing timer and service files...${NC}"
        sudo rm -f "$timer_file"
        sudo rm -f "$service_file"

        # Remove backup script if it exists
        if [[ -f "$backup_script" ]]; then
            echo -e "\n${CYAN}Removing backup script for '${WORLD_NAME}'...${NC}"
            rm -f "$backup_script"
        fi

        echo -e "\n${CYAN}Reloading systemd daemon and cleaning up failed units...${NC}"
        sudo systemctl daemon-reload
        sudo systemctl reset-failed

        echo -e "\n${GREEN}✅ Auto-backup for world '${WORLD_NAME}' has been fully removed!${NC}"
    else
        echo -e "\n${YELLOW}Removal canceled. Auto-backup remains active.${NC}"
    fi

    prompt_continue
}

if [[ "$(basename "$0")" == backup_*.sh ]]; then
    exit 0
fi

# ============================================================
# Steam and Valheim Management
# ============================================================

function install_or_update_steamcmd() {
    echo -e "\n${CYAN}========== Install / Update / Reinstall SteamCMD ==========${NC}"

    if [[ -z "${STEAMCMD_DIR:-}" ]]; then
        echo -e "${RED}ERROR: SteamCMD directory not set. Please check config.${NC}"
        prompt_continue
        return
    fi

    local steamcmd_dir="${STEAMCMD_DIR}"
    local steamcmd_file="${steamcmd_dir}/steamcmd.sh"

    if [[ -f "$steamcmd_file" ]]; then
        echo -e "${YELLOW}SteamCMD detected at ${steamcmd_dir}.${NC}"
        echo "1) Update SteamCMD (run self-update)"
        echo "2) Reinstall SteamCMD (wipe and reinstall)"
        echo "3) Cancel"
        echo -n -e "\nEnter your choice: "
        read choice

        case "$choice" in
            1)
                echo -e "\n${CYAN}Running SteamCMD self-update...${NC}"
                "$steamcmd_file" +quit
                echo -e "\n${GREEN}✅ SteamCMD self-update completed.${NC}"
                prompt_continue
                return
                ;;
            2)
                echo -e "\n${CYAN}Proceeding with SteamCMD reinstallation...${NC}"
                rm -rf "$steamcmd_dir"
                ;;
            3)
                echo -e "\n${CYAN}SteamCMD installation/update canceled.${NC}"
                prompt_continue
                return
                ;;
            *)
                echo -e "\n${RED}Invalid choice. Canceling operation.${NC}"
                prompt_continue
                return
                ;;
        esac
    else
        echo -e "\n${CYAN}SteamCMD not detected. Proceeding with fresh install...${NC}"
    fi

    echo -e "\n${CYAN}Creating SteamCMD directory...${NC}"
    mkdir -p "$steamcmd_dir"
    cd "$steamcmd_dir" || {
        echo -e "${RED}Failed to access ${steamcmd_dir}. Aborting.${NC}"
        prompt_continue
        return
    }

    echo -e "\n${CYAN}Downloading latest SteamCMD...${NC}"
    curl -sO https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz

    if [[ ! -f "steamcmd_linux.tar.gz" ]]; then
        echo -e "${RED}Download failed. Aborting installation.${NC}"
        prompt_continue
        return
    fi

    echo -e "\n${CYAN}Extracting SteamCMD...${NC}"
    tar -xzf steamcmd_linux.tar.gz
    rm -f steamcmd_linux.tar.gz

    if [[ -f "$steamcmd_file" ]]; then
        echo -e "\n${GREEN}✅ SteamCMD installed/updated successfully at ${steamcmd_dir}.${NC}"
    else
        echo -e "\n${RED}❌ SteamCMD installation failed. Please check manually.${NC}"
    fi

    prompt_continue
}

function install_or_update_valheim_server() {
    echo -e "\n${CYAN}========== Install / Update Valheim Server ==========${NC}"

    if [[ -z "${VALHEIM_DIR:-}" || -z "${STEAMCMD_DIR:-}" || -z "${VALHEIM_APP_ID:-}" ]]; then
        echo -e "${RED}ERROR: Required paths not set. Please check config.${NC}"
        prompt_continue
        return
    fi

    local server_dir="${VALHEIM_DIR}"
    local steamcmd="${STEAMCMD_DIR}/steamcmd.sh"

    if [[ ! -f "$steamcmd" ]]; then
        echo -e "${RED}SteamCMD is not installed! Please install SteamCMD first.${NC}"
        prompt_continue
        return
    fi

    # Check if Valheim server already installed
    if [[ -f "${server_dir}/valheim_server.x86_64" ]]; then
        echo -e "${YELLOW}Valheim server detected in ${server_dir}.${NC}"
        echo "1) Reinstall Valheim Server (fresh install)"
        echo "2) Update Valheim Server (keep all files)"
        echo "3) Cancel"
        echo -n -e "\nEnter your choice: "
        read reinstall_choice

        case "$reinstall_choice" in
            1)
                echo -e "\n${CYAN}Proceeding with full reinstall...${NC}"
                find "$server_dir" -mindepth 1 -maxdepth 1 ! -name "valheim_data" -exec rm -rf {} +
                ;;
            2)
                echo -e "\n${CYAN}Proceeding with update only...${NC}"
                ;;
            *)
                echo -e "\n${CYAN}Installation canceled.${NC}"
                prompt_continue
                return
                ;;
        esac
    else
        echo -e "\n${CYAN}No existing Valheim server detected. Proceeding with fresh install...${NC}"
    fi

    mkdir -p "$server_dir"

    echo -e "\n${CYAN}Running SteamCMD to install/update Valheim server...${NC}"
    "$steamcmd" +@sSteamCmdForcePlatformType linux +force_install_dir "$server_dir" +login anonymous +app_update "$VALHEIM_APP_ID" validate +quit

    if [[ -f "${server_dir}/valheim_server.x86_64" ]]; then
        echo -e "\n${GREEN}✅ Valheim server installed/updated successfully!${NC}"
    else
        echo -e "\n${RED}❌ Valheim server installation failed. Please check SteamCMD logs.${NC}"
        prompt_continue
        return
    fi

    # Install Crossplay Prerequisites
    echo -e "\n${CYAN}========== Installing Crossplay Prerequisites ==========${NC}"
    sudo apt update
    sudo apt install -y libpulse-dev libatomic1

    # Check libc6 version
    libc_version=$(ldd --version | head -n 1 | awk '{print $NF}')
    required_version="2.29"

    dpkg --compare-versions "$libc_version" ge "$required_version"
    if [[ $? -ne 0 ]]; then
        echo -e "\n${YELLOW}⚠️ WARNING: Your system libc6 version is ${libc_version}.${NC}"
        echo -e "${YELLOW}Crossplay requires libc6 version 2.29 or newer.${NC}"
        echo -e "${YELLOW}Consider upgrading to Debian 11 (Bullseye) or Ubuntu 20.04+ if you plan to use Crossplay.${NC}"
    else
        echo -e "\n${GREEN}✅ libc6 version ${libc_version} is compatible with Crossplay.${NC}"
    fi

    prompt_continue
}

# ============================================================
# Menu Functions
# ============================================================

function main_menu() {
    while true; do
        clear

        # Gather Server Info
        INTERNAL_IP=$(hostname -I | awk '{print $1}')
        EXTERNAL_IP=$(curl -s ifconfig.me || echo "Unavailable")
        UPTIME=$(uptime -p)
        CURRENT_TIME=$(date +"%Y-%m-%d %I:%M:%S %p %Z")

        # Check Service Status if world is selected
        if [[ -n "${WORLD_NAME:-}" ]]; then
            SERVICE_NAME="valheimserver-${WORLD_NAME}.service"
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                WORLD_STATUS="${GREEN}(Running)${NC}"
            else
                WORLD_STATUS="${YELLOW}(Stopped)${NC}"
            fi
        else
            WORLD_STATUS="${YELLOW}(No World Selected)${NC}"
        fi

        #Display Current World Port
        SERVICE_FILE="/etc/systemd/system/valheimserver-${WORLD_NAME}.service"

        if [[ -f "$SERVICE_FILE" ]]; then
            ACTUAL_PORT=$(grep -oP '(?<=-port )\d+' "$SERVICE_FILE")
        else
            ACTUAL_PORT="${RED}Unknown${NC}"
        fi

        # Resolve latest join code for current world (safe global use)
        # ─── at the top of your menu, once per invocation ─────────────────────────────
        join_code=""
        log_file="${LOG_DIR}/${WORLD_NAME}_server.log"

        if [[ -f "$log_file" ]]; then
            # -m1 stops after the first match, 2>/dev/null silences errors,
            # || : prevents grep’s exit‐1 from killing the script
            join_code=$(
                grep -m1 -oP '(?<=registered with join code )\d+' "$log_file" \
                    2>/dev/null || :
            )
        fi

        # Auto-Backup Status
        TIMER_FILE="/etc/systemd/system/valheim_backup_${WORLD_NAME}.timer"
        if [ -f "$TIMER_FILE" ]; then
            ON_CALENDAR=$(grep "OnCalendar=" "$TIMER_FILE" | cut -d'=' -f2)
            case "$ON_CALENDAR" in
                "*:0/30")
                    BACKUP_INTERVAL="Every 30 minutes"
                    ;;
                "hourly")
                    BACKUP_INTERVAL="Every 1 hour"
                    ;;
                "*:0/180")
                    BACKUP_INTERVAL="Every 3 hours"
                    ;;
                *)
                    BACKUP_INTERVAL="Unknown Interval"
                    ;;
            esac
            AUTO_BACKUP_STATUS="${GREEN}ON (${BACKUP_INTERVAL})${NC}"
        else
            AUTO_BACKUP_STATUS="${RED}OFF${NC}"
        fi

        # Find latest backup file (manual or auto)
        LATEST_BACKUP_FILE=$(ls -t "${BACKUP_DIR}/${WORLD_NAME}_backup_"*.tar.gz 2>/dev/null | head -n 1 || true)
        # Make sure LAST_BACKUP is always defined
        LAST_BACKUP=""

        if [[ -n "$LATEST_BACKUP_FILE" ]]; then
            BACKUP_FILENAME=$(basename "$LATEST_BACKUP_FILE")

            if [[ "$BACKUP_FILENAME" =~ _backup_ ]]; then
                BACKUP_TIMESTAMP_PART="${BACKUP_FILENAME#*_backup_}"
                BACKUP_TIMESTAMP_PART="${BACKUP_TIMESTAMP_PART%.tar.gz}"

                if [[ -n "$BACKUP_TIMESTAMP_PART" ]]; then
                    BACKUP_DATE=$(echo "$BACKUP_TIMESTAMP_PART" | cut -d'-' -f1-3)
                    BACKUP_TIME=$(echo "$BACKUP_TIMESTAMP_PART" | cut -d'-' -f4)

                    HOUR=${BACKUP_TIME:0:2}
                    MINUTE=${BACKUP_TIME:2:2}

                    if ((10#$HOUR == 0)); then
                        STD_HOUR=12
                        AMPM="AM"
                    elif ((10#$HOUR < 12)); then
                        STD_HOUR=$((10#$HOUR))
                        AMPM="AM"
                    elif ((10#$HOUR == 12)); then
                        STD_HOUR=12
                        AMPM="PM"
                    else
                        STD_HOUR=$((10#$HOUR - 12))
                        AMPM="PM"
                    fi

                    LAST_BACKUP="${BACKUP_DATE} $(printf "%02d" ${STD_HOUR}):${MINUTE} ${AMPM}"
                else
                    LAST_BACKUP="${RED}No Valid Backup Timestamp${NC}"
                fi
            else
                LAST_BACKUP="${RED}No Backup Data${NC}"
            fi
        else
            LAST_BACKUP="${RED}No Backups Found${NC}"
        fi

        # Print Header
        echo -e "${BLUE}========== Valheim Server Manager ==========${NC}"
        echo -e "Internal IP: ${GREEN}${INTERNAL_IP}${NC}"
        echo -e "External IP: ${GREEN}${EXTERNAL_IP}${NC}"
        echo -e "Current World: ${GREEN}${WORLD_NAME}${NC} ${WORLD_STATUS}"
        echo -e "Main Port: ${GREEN}${ACTUAL_PORT}${NC}"
        if [[ -n "${join_code}" ]]; then
            echo -e "Join Code: ${GREEN}${join_code}${NC}"
        else
            echo -e "Crossplay: ${YELLOW}Not enabled${NC}"
        fi
        echo -e "Uptime: ${GREEN}${UPTIME}${NC}"
        echo -e "Current Time: ${GREEN}${CURRENT_TIME}${NC}"
        echo -e "Auto-Backup: ${AUTO_BACKUP_STATUS}"
        if [[ -n "${LAST_BACKUP}" ]]; then
            echo -e "Last Backup: ${CYAN}${LAST_BACKUP}${NC}"
        fi
        echo -e "${BLUE}============================================${NC}"

        echo
        echo -e "${CYAN}⚡ Quick Actions${NC}"
        echo "1) Start Server"
        echo "2) Stop Server"
        echo "3) Server Status"

        echo
        echo -e "${CYAN}🌍 World Actions${NC}"
        echo "4) List Worlds"
        echo "5) Select World"
        echo "6) Generate New World"
        echo "7) Backup World"
        echo "8) Restore World"
        echo "9) Delete World"
        echo "10) Enable/Edit Auto Backup"
        echo "11) Disable Auto Backup"

        echo
        echo -e "${CYAN}🛠️  Server Maintenance${NC}"
        echo "12) Update Server OS"
        echo "13) Reboot Server"
        echo "14) View Server Info"

        echo
        echo -e "${CYAN}🎮 Steam/Valheim Management${NC}"
        echo "15) Install/Update SteamCMD"
        echo "16) Install/Update Valheim"

        echo
        echo -e "${CYAN}🚪 Exit${NC}"
        echo "0) Exit"
        echo -e "${BLUE}============================================${NC}"

        read -rp "Choose an option: " choice

        case "$choice" in
            1) start_valheim_server ;;
            2) stop_valheim_server ;;
            3) server_status ;;
            4) list_worlds ;;
            5) select_world ;;
            6) generate_new_world ;;
            7) backup_world ;;
            8) restore_world ;;
            9) delete_world ;;
            10) setup_auto_backup ;;
            11) remove_auto_backup ;;
            12) update_server_files ;;
            13) reboot_server ;;
            14) view_server_info ;;
            15) install_or_update_steamcmd ;;
            16) install_or_update_valheim_server ;;
            0) exit 0 ;;
            *)
                echo -e "${RED}Invalid option. Please choose a valid number.${NC}"
                sleep 2
                ;;
        esac
    done
}

# ============================================================
# Start Program
# ============================================================

main_menu
