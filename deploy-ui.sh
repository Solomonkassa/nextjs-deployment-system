#!/usr/bin/env bash

# =============================================================================
# Interactive Next.js Deployment UI
# Version: 2.0.0
# =============================================================================

set -euo pipefail

# ASCII Art and Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ASCII Art Logo
show_logo() {
    clear
    cat << "EOF"

╔╦╗┌─┐┌┬┐┌─┐┬ ┬┌─┐┬─┐┌─┐  ╔╦╗┌─┐┌─┐┬─┐┌─┐┌─┐┌─┐┬─┐
 ║ ├┤ │││├─┘├─┤│ │├┬┘├┤    ║║├┤ ├─┘├┬┘│  ├┤ │ │├┬┘
 ╩ └─┘┴ ┴┴  ┴ ┴└─┘┴└─└─┘  ╩ ╩└─┘┴  ┴└─└─┘└─┘└─┘┴└─
  Advanced Deployment System v2.0.0

EOF
}

# Spinner animation
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Progress bar
progress_bar() {
    local duration=$1
    local steps=50
    local step_delay=$(echo "scale=3; $duration/$steps" | bc)
    
    printf "["
    for ((i=0; i<steps; i++)); do
        printf "▓"
        sleep $step_delay
    done
    printf "] Done!\n"
}

# Interactive menu
show_menu() {
    show_logo
    
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         DEPLOYMENT DASHBOARD             ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║  1. 🚀 Deploy to Production             ║${NC}"
    echo -e "${CYAN}║  2. 🔄 Deploy to Staging                ║${NC}"
    echo -e "${CYAN}║  3. 🧪 Deploy to Development            ║${NC}"
    echo -e "${CYAN}║  4. 📊 View Deployment Status           ║${NC}"
    echo -e "${CYAN}║  5. 🔍 Health Check & Monitoring        ║${NC}"
    echo -e "${CYAN}║  6. ⚙️  Configuration & Settings         ║${NC}"
    echo -e "${CYAN}║  7. 📦 Backup Management                ║${NC}"
    echo -e "${CYAN}║  8. 🗑️  Cleanup & Maintenance            ║${NC}"
    echo -e "${CYAN}║  9. 📄 View Logs                        ║${NC}"
    echo -e "${CYAN}║  0. ❌ Exit                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo -e ""
    
    read -p "Select an option (0-9): " choice
    echo ""
}

# Deployment selection
select_environment() {
    echo -e "${YELLOW}Select Deployment Environment:${NC}"
    echo "1) Production (Live)"
    echo "2) Staging (Pre-production)"
    echo "3) Development (Testing)"
    echo "4) Custom Environment"
    echo "5) Back to Main Menu"
    
    read -p "Enter choice: " env_choice
    
    case $env_choice in
        1)
            ENVIRONMENT="production"
            confirm_deployment
            ;;
        2)
            ENVIRONMENT="staging"
            confirm_deployment
            ;;
        3)
            ENVIRONMENT="development"
            confirm_deployment
            ;;
        4)
            read -p "Enter environment name: " ENVIRONMENT
            confirm_deployment
            ;;
        5)
            return
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            sleep 1
            select_environment
            ;;
    esac
}

# Deployment confirmation
confirm_deployment() {
    show_logo
    echo -e "${YELLOW}══════════════════════════════════════════${NC}"
    echo -e "${YELLOW}          DEPLOYMENT CONFIRMATION         ${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════${NC}"
    echo ""
    echo -e "Environment: ${GREEN}$ENVIRONMENT${NC}"
    echo -e "Application: ${GREEN}nextjs-app${NC}"
    echo -e "Timestamp: ${GREEN}$(date)${NC}"
    echo ""
    echo -e "${RED}⚠  WARNING: This will deploy to ${ENVIRONMENT^^} environment${NC}"
    echo ""
    
    read -p "Are you sure you want to proceed? (yes/no): " confirm
    
    if [[ "$confirm" == "yes" || "$confirm" == "y" ]]; then
        read -p "Enter deployment reason/description: " reason
        echo "$(date) - $ENVIRONMENT - $USER - $reason" >> deployment_log.txt
        
        execute_deployment
    else
        echo -e "${YELLOW}Deployment cancelled${NC}"
        sleep 2
    fi
}

# Execute deployment with visual feedback
execute_deployment() {
    show_logo
    echo -e "${BLUE}══════════════════════════════════════════${NC}"
    echo -e "${BLUE}          STARTING DEPLOYMENT             ${NC}"
    echo -e "${BLUE}══════════════════════════════════════════${NC}"
    echo ""
    
    # Start deployment in background
    ./deploy.sh --environment "$ENVIRONMENT" &
    local deploy_pid=$!
    
    # Show spinner while deploying
    spinner $deploy_pid &
    local spinner_pid=$!
    
    # Wait for deployment to complete
    wait $deploy_pid
    local exit_code=$?
    
    # Stop spinner
    kill $spinner_pid 2>/dev/null
    
    # Show result
    echo -e "\n"
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}══════════════════════════════════════════${NC}"
        echo -e "${GREEN}       DEPLOYMENT SUCCESSFUL!            ${NC}"
        echo -e "${GREEN}══════════════════════════════════════════${NC}"
        echo ""
        show_deployment_info
    else
        echo -e "${RED}══════════════════════════════════════════${NC}"
        echo -e "${RED}        DEPLOYMENT FAILED!               ${NC}"
        echo -e "${RED}══════════════════════════════════════════${NC}"
        echo ""
        show_error_logs
    fi
    
    read -p "Press Enter to continue..."
}

# Show deployment information
show_deployment_info() {
    echo -e "${CYAN}Deployment Information:${NC}"
    echo "────────────────────────────"
    
    # Get container info
    echo -e "${YELLOW}Container Status:${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep nextjs
    
    # Get resource usage
    echo -e "\n${YELLOW}Resource Usage:${NC}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | grep nextjs
    
    # Get application URL
    echo -e "\n${YELLOW}Application URLs:${NC}"
    echo "  Main: http://localhost:3000"
    echo "  Health: http://localhost:3000/api/health"
    
    # Get logs tail
    echo -e "\n${YELLOW}Recent Logs:${NC}"
    docker logs --tail 5 $(docker ps -q --filter "name=nextjs") 2>/dev/null || echo "No logs available"
}

# Show error logs
show_error_logs() {
    echo -e "${RED}Error Details:${NC}"
    echo "────────────────────"
    
    # Check Docker logs
    local error_containers=$(docker ps -a --filter "exited=1" --format "{{.Names}}")
    
    for container in $error_containers; do
        echo -e "\n${YELLOW}Errors in $container:${NC}"
        docker logs --tail 20 "$container" 2>/dev/null | grep -i error || echo "No errors found"
    done
    
    # Check deployment logs
    local latest_log=$(ls -t logs/*.log 2>/dev/null | head -1)
    if [[ -f "$latest_log" ]]; then
        echo -e "\n${YELLOW}Deployment log excerpt:${NC}"
        tail -20 "$latest_log" | grep -E "(ERROR|FAILED|error|failed)"
    fi
}

# Health check dashboard
health_dashboard() {
    show_logo
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}        HEALTH CHECK DASHBOARD           ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    
    while true; do
        clear
        show_logo
        echo -e "${CYAN}Real-time Monitoring${NC}"
        echo "──────────────────────"
        
        # Check application health
        local health_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health || echo "000")
        if [[ "$health_status" == "200" ]]; then
            echo -e "Application: ${GREEN}✓ HEALTHY${NC}"
        else
            echo -e "Application: ${RED}✗ UNHEALTHY (Code: $health_status)${NC}"
        fi
        
        # Check database
        if docker-compose exec -T db pg_isready -U postgres >/dev/null 2>&1; then
            echo -e "Database:    ${GREEN}✓ CONNECTED${NC}"
        else
            echo -e "Database:    ${RED}✗ DISCONNECTED${NC}"
        fi
        
        # Check Redis
        if docker-compose exec -T redis redis-cli ping >/dev/null 2>&1; then
            echo -e "Redis:       ${GREEN}✓ CONNECTED${NC}"
        else
            echo -e "Redis:       ${RED}✗ DISCONNECTED${NC}"
        fi
        
        # Show performance metrics
        echo -e "\n${CYAN}Performance Metrics${NC}"
        echo "──────────────────────"
        
        # CPU and Memory
        local stats=$(docker stats --no-stream --format "{{.CPUPerc}} {{.MemPerc}}" $(docker ps -q) 2>/dev/null | head -1)
        if [[ -n "$stats" ]]; then
            echo "CPU Usage:  $(echo $stats | cut -d' ' -f1)"
            echo "Memory:     $(echo $stats | cut -d' ' -f2)"
        fi
        
        # Response time
        local response_time=$(curl -s -w "%{time_total}\n" -o /dev/null http://localhost:3000/api/health)
        echo "Response:   ${response_time}s"
        
        # Uptime
        local uptime=$(docker inspect --format='{{.State.StartedAt}}' $(docker ps -q --filter "name=app") 2>/dev/null | head -1)
        if [[ -n "$uptime" ]]; then
            echo "Uptime:     $(date -d "$uptime" +"%Hh %Mm")"
        fi
        
        echo -e "\n${YELLOW}Press 'q' to quit, any other key to refresh...${NC}"
        read -t 5 -n 1 key
        
        if [[ "$key" == "q" ]]; then
            break
        fi
    done
}

# Configuration menu
configuration_menu() {
    while true; do
        clear
        show_logo
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo -e "${CYAN}           CONFIGURATION MENU            ${NC}"
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo ""
        echo "1) View Current Configuration"
        echo "2) Edit Environment Variables"
        echo "3) Docker Configuration"
        echo "4) Nginx Configuration"
        echo "5) Backup Configuration"
        echo "6) Notification Settings"
        echo "7) Security Settings"
        echo "0) Back to Main Menu"
        echo ""
        
        read -p "Select option: " config_choice
        
        case $config_choice in
            1)
                view_configuration
                ;;
            2)
                edit_environment
                ;;
            3)
                docker_configuration
                ;;
            4)
                nginx_configuration
                ;;
            5)
                backup_configuration
                ;;
            6)
                notification_configuration
                ;;
            7)
                security_configuration
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# View current configuration
view_configuration() {
    clear
    echo -e "${YELLOW}Current Configuration:${NC}"
    echo "─────────────────────────"
    
    echo -e "\n${CYAN}Environment Variables:${NC}"
    if [[ -f ".env" ]]; then
        grep -v '^#' .env | grep -v '^$'
    else
        echo "No .env file found"
    fi
    
    echo -e "\n${CYAN}Docker Information:${NC}"
    docker version 2>/dev/null | head -5
    
    echo -e "\n${CYAN}System Information:${NC}"
    echo "OS: $(uname -s)"
    echo "Kernel: $(uname -r)"
    echo "CPU: $(nproc) cores"
    echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    
    read -p "Press Enter to continue..."
}

# Backup management
backup_management() {
    while true; do
        clear
        show_logo
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo -e "${CYAN}           BACKUP MANAGEMENT             ${NC}"
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo ""
        echo "1) Create Manual Backup"
        echo "2) List Available Backups"
        echo "3) Restore from Backup"
        echo "4) Delete Old Backups"
        echo "5) Backup Configuration"
        echo "0) Back to Main Menu"
        echo ""
        
        read -p "Select option: " backup_choice
        
        case $backup_choice in
            1)
                create_backup
                ;;
            2)
                list_backups
                ;;
            3)
                restore_backup
                ;;
            4)
                delete_backups
                ;;
            5)
                backup_configuration
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Create manual backup
create_backup() {
    echo -e "${BLUE}Creating manual backup...${NC}"
    
    local backup_name="manual_$(date +%Y%m%d_%H%M%S)"
    local backup_dir="backups/$backup_name"
    
    mkdir -p "$backup_dir"
    
    # Backup Docker volumes
    docker run --rm \
        -v nextjs_data:/data \
        -v "$(pwd)/$backup_dir:/backup" \
        alpine tar czf /backup/data.tar.gz -C /data . 2>/dev/null || true
    
    # Backup configuration
    cp -r config "$backup_dir/" 2>/dev/null || true
    cp .env* "$backup_dir/" 2>/dev/null || true
    
    # Backup database dump
    docker-compose exec -T db pg_dump -U postgres app_db > "$backup_dir/database.sql" 2>/dev/null || true
    
    echo -e "${GREEN}✓ Backup created: $backup_dir${NC}"
    echo -e "Size: $(du -sh "$backup_dir" | cut -f1)"
    
    read -p "Press Enter to continue..."
}

# Log viewer
log_viewer() {
    while true; do
        clear
        show_logo
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo -e "${CYAN}              LOG VIEWER                 ${NC}"
        echo -e "${CYAN}══════════════════════════════════════════${NC}"
        echo ""
        
        # List log files
        echo -e "${YELLOW}Available Logs:${NC}"
        local logs=($(find logs -name "*.log" -type f 2>/dev/null | sort -r))
        
        if [[ ${#logs[@]} -eq 0 ]]; then
            echo "No log files found"
        else
            for i in "${!logs[@]}"; do
                echo "$((i+1))) $(basename "${logs[$i]}") - $(stat -c %y "${logs[$i]}" 2>/dev/null | cut -d' ' -f1)"
            done
        fi
        
        echo ""
        echo "d) Docker Container Logs"
        echo "s) System Logs"
        echo "0) Back to Main Menu"
        echo ""
        
        read -p "Select option: " log_choice
        
        case $log_choice in
            [1-9]*)
                if [[ $log_choice -le ${#logs[@]} ]]; then
                    view_log_file "${logs[$((log_choice-1))]}"
                fi
                ;;
            d|D)
                view_docker_logs
                ;;
            s|S)
                view_system_logs
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# View log file with filtering
view_log_file() {
    local log_file="$1"
    
    while true; do
        clear
        echo -e "${CYAN}Viewing: $(basename "$log_file")${NC}"
        echo "─────────────────────────────"
        
        echo -e "\n${YELLOW}Options:${NC}"
        echo "1) Show all lines"
        echo "2) Show errors only"
        echo "3) Show last 50 lines"
        echo "4) Search in logs"
        echo "5) Follow (tail -f)"
        echo "0) Back"
        echo ""
        
        read -p "Select option: " view_choice
        
        case $view_choice in
            1)
                less "$log_file"
                ;;
            2)
                grep -i "error\|failed\|exception" "$log_file" | less
                ;;
            3)
                tail -50 "$log_file" | less
                ;;
            4)
                read -p "Search term: " search_term
                grep -i "$search_term" "$log_file" | less
                ;;
            5)
                echo -e "${YELLOW}Following logs (Ctrl+C to stop)...${NC}"
                tail -f "$log_file"
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Main loop
main() {
    while true; do
        show_menu
        
        case $choice in
            1)
                ENVIRONMENT="production"
                confirm_deployment
                ;;
            2)
                ENVIRONMENT="staging"
                confirm_deployment
                ;;
            3)
                ENVIRONMENT="development"
                confirm_deployment
                ;;
            4)
                health_dashboard
                ;;
            5)
                health_dashboard
                ;;
            6)
                configuration_menu
                ;;
            7)
                backup_management
                ;;
            8)
                ./scripts/cleanup.sh --interactive
                ;;
            9)
                log_viewer
                ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}This script should not be run as root${NC}"
    exit 1
fi

# Check dependencies
check_dependencies() {
    local deps=("docker" "docker-compose" "curl")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
        exit 1
    fi
}

# Initialize
check_dependencies
main