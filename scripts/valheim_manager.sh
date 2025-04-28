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
SESSION_FILE="${SERVER_DIR}/last_session.txt"

if [[ -f "${SESSION_FILE}" ]]; then
    source "${SESSION_FILE}"
fi

# Dynamic session-built variables
LOG_FILE="${LOG_DIR}/${WORLD_NAME}_server_start.log"

# ============================================================
# Other Helper Functions
# ============================================================

# Raspberry Pi auto-check
ARCH=$(uname -m)

if [[ "$ARCH" == "aarch64" || "$ARCH" == "armv7l" ]]; then
    if [[ ! -f "${VALHEIM_DIR}/.rpi_ready" ]]; then
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

    for ((i=1; i<=retries; i++)); do
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

    for ((i=1; i<=retries; i++)); do
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

    for ((i=1; i<=retries; i++)); do
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
        WORLD_NAME="${worlds[$((choice-1))]}"
        echo -e "${GREEN}✅ World '${WORLD_NAME}' selected.${NC}"

        # Immediately save to last_session.txt
        echo "WORLD_NAME=${WORLD_NAME}" > "${SESSION_FILE}"
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

    echo -n "Enter new World Name: "
    read world_name

    if [[ $existing_worlds -eq 0 ]]; then
        echo -n "Enter Server Name: "
        read server_name
    else
        echo -e "\n${CYAN}Checking existing Valheim services for Server Name...${NC}"
        for service in /etc/systemd/system/valheimserver-*.service; do
            if [[ -f "$service" ]]; then
                extracted_name=$(grep -oP '(?<=-name ")[^"]*' "$service")
                if [[ -n "$extracted_name" ]]; then
                    server_name="$extracted_name"
                    echo -e "${YELLOW}Reusing Server Name: '${server_name}' (detected from ${service})${NC}"
                    break
                fi
            fi
        done

        if [[ -z "$server_name" ]]; then
            echo -e "${YELLOW}No valid Server Name found in existing services.${NC}"
            echo -n "Enter Server Name: "
            read server_name
        fi
    fi

    echo -n "Enter Port Number (default 2456): "
    read port
    port=${port:-2456}

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
    echo -e "${YELLOW}Ports 2456-2458 UDP must be fully open. No extra installs needed — FAB support is built-in.${NC}"
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

    # Build launch flags (include modifiers cleanly)
    launch_flags="-nographics -batchmode -name \"${server_name}\" -port ${port} -world \"${world_name}\" -password \"${password}\" -public ${public_flag} ${crossplay_flag} ${modifiers_flag}"

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

    echo -e "\n${GREEN}✅ New world '${world_name}' created and server started successfully!${NC}"
    echo -e "${CYAN}⚡ Your world seed will be available after the first save completes.${NC}"
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

function reboot_server(){
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

    echo -e "${CYAN}Creating backup for world: ${WORLD_NAME}${NC}"

    mkdir -p "$BACKUP_DIR"

    timestamp=$(date +"%Y-%m-%d-%H%M")
    backup_file="${BACKUP_DIR}/${WORLD_NAME}_backup_${timestamp}.tar.gz"

    # Create tar.gz backup
    tar -czvf "$backup_file" "${WORLD_DIR}/${WORLD_NAME}.db" "${WORLD_DIR}/${WORLD_NAME}.fwl"

    echo -e "${GREEN}✅ Backup created: ${backup_file}${NC}"

    # Clean up old backups
    backup_count=$(ls "${BACKUP_DIR}/${WORLD_NAME}_backup_"*.tar.gz 2>/dev/null | wc -l)
    
    if (( backup_count > 10 )); then
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

            if (( 10#$hour == 0 )); then
                std_hour=12
                ampm="AM"
            elif (( 10#$hour < 12 )); then
                std_hour=$((10#$hour))
                ampm="AM"
            elif (( 10#$hour == 12 )); then
                std_hour=12
                ampm="PM"
            else
                std_hour=$((10#$hour - 12))
                ampm="PM"
            fi

            std_time="${std_hour}:${minute} ${ampm}"

            printf "%-4s %-25s %-12s %-8s\n" "$((i+1)))" "$world_name" "$date_part" "$std_time"
        done

        if [ ${#all_backups[@]} -gt ${#backups[@]} ]; then
            echo "$(( ${#backups[@]} + 1 ))) Load more backups..."
        fi

        echo -n -e "\nEnter number to restore (or 'q' to quit): "
        read choice

        if [[ "$choice" == "q" ]]; then
            echo -e "\n${YELLOW}Restore canceled.${NC}"
            prompt_continue
            return
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#backups[@]}" ]; then
                selected_backup="${backups[$((choice-1))]}"
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
            elif [ "$choice" -eq $(( ${#backups[@]} + 1 )) ] && [ ${#all_backups[@]} -gt ${#backups[@]} ]; then
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

    # Ensure BackupScripts directory exists
    mkdir -p "$backup_scripts_dir"

    # Create backup script if not already existing
    if [ ! -f "$backup_script" ]; then
        echo -e "\n${CYAN}Creating dedicated backup script for '${WORLD_NAME}'...${NC}"
        tee "$backup_script" > /dev/null <<EOF
#!/bin/bash
source ${SERVER_DIR}/config.conf
WORLD_NAME="${WORLD_NAME}"
backup_world
EOF
        chmod +x "$backup_script"
    else
        echo -e "\n${CYAN}Backup script for '${WORLD_NAME}' already exists. Skipping script creation.${NC}"
    fi

    # Create systemd service
    echo -e "\n${CYAN}Creating backup service for '${WORLD_NAME}'...${NC}"
    sudo tee "$service_file" > /dev/null <<EOF
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
    sudo tee "$timer_file" > /dev/null <<EOF
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
    cd "$steamcmd_dir" || { echo -e "${RED}Failed to access ${steamcmd_dir}. Aborting.${NC}"; prompt_continue; return; }

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
fi

# Find latest backup file (manual or auto)
LATEST_BACKUP_FILE=$(ls -t "${BACKUP_DIR}/${WORLD_NAME}_backup_"*.tar.gz 2>/dev/null | head -n 1 || true)

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

            if (( 10#$HOUR == 0 )); then
                STD_HOUR=12
                AMPM="AM"
            elif (( 10#$HOUR < 12 )); then
                STD_HOUR=$((10#$HOUR))
                AMPM="AM"
            elif (( 10#$HOUR == 12 )); then
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
        echo -e "Main Port: ${GREEN}${SERVER_PORT}${NC}"
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
	echo "6) Generate New  World"
        echo "7) Backup World"
        echo "8) Restore World"
	echo "9) Enable/Edit Auto Backup"
        echo "10) Disable Auto Backup"

        echo
        echo -e "${CYAN}🛠️ Server Maintenance${NC}"
        echo "11) Update Server"
        echo "12) Reboot Server"
        echo "13) View Server Info"

        echo
        echo -e "${CYAN}🎮 Steam/Valheim Management${NC}"
        echo "14) Install/Update SteamCMD"
        echo "15) Install/Update Valheim"

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
	    9) setup_auto_backup ;;
	    10) remove_auto_backup ;;
            11) update_server_files ;;
            12) reboot_server ;;
            13) view_server_info ;;
            14) install_or_update_steamcmd ;;
            15) install_or_update_valheim_server ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid option. Please choose a valid number.${NC}"; sleep 2 ;;
        esac
    done
}


# ============================================================
# Start Program
# ============================================================

main_menu
