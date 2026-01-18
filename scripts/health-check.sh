#!/usr/bin/env bash

# Advanced Health Check Script
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/../config/health-config.yml"

# Colors
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source <(yq e '. | to_entries | map("export \(.key)=\(.value | tostring)") | .[]' "$CONFIG_FILE")
    fi
}

# Check application health
check_app_health() {
    local url="${1:-http://localhost:3000/api/health}"
    local timeout="${2:-10}"
    
    echo -e "${YELLOW}Checking application health...${NC}"
    
    local start_time=$(date +%s%N)
    local response=$(curl -s -f -m "$timeout" -w "%{http_code}" "$url" || echo "000")
    local end_time=$(date +%s%N)
    local response_time=$(( (end_time - start_time) / 1000000 ))
    
    if [[ "$response" == "200" ]]; then
        echo -e "${GREEN}✓ Application is healthy (${response_time}ms)${NC}"
        return 0
    else
        echo -e "${RED}✗ Application unhealthy (HTTP $response, ${response_time}ms)${NC}"
        return 1
    fi
}

# Check database
check_database() {
    echo -e "${YELLOW}Checking database...${NC}"
    
    if docker-compose exec -T db pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
        # Check replication lag if applicable
        local lag=$(docker-compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
            -t -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;" 2>/dev/null || echo "0")
        
        echo -e "${GREEN}✓ Database is connected${NC}"
        
        # Check table sizes
        local table_sizes=$(docker-compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
            -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) 
                FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') 
                ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC LIMIT 5;" 2>/dev/null)
        
        echo -e "  Table sizes:\n$table_sizes"
        
        return 0
    else
        echo -e "${RED}✗ Database connection failed${NC}"
        return 1
    fi
}

# Check Redis
check_redis() {
    echo -e "${YELLOW}Checking Redis...${NC}"
    
    if docker-compose exec -T redis redis-cli -a "$REDIS_PASSWORD" ping >/dev/null 2>&1; then
        local memory=$(docker-compose exec -T redis redis-cli -a "$REDIS_PASSWORD" info memory | grep used_memory_human | cut -d: -f2)
        local connected_clients=$(docker-compose exec -T redis redis-cli -a "$REDIS_PASSWORD" info clients | grep connected_clients | cut -d: -f2)
        
        echo -e "${GREEN}✓ Redis is connected${NC}"
        echo -e "  Memory used: $memory"
        echo -e "  Connected clients: $connected_clients"
        
        return 0
    else
        echo -e "${RED}✗ Redis connection failed${NC}"
        return 1
    fi
}

# Check disk space
check_disk_space() {
    echo -e "${YELLOW}Checking disk space...${NC}"
    
    local threshold=${DISK_THRESHOLD:-90}
    local usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    
    if [[ $usage -lt $threshold ]]; then
        echo -e "${GREEN}✓ Disk usage: ${usage}%${NC}"
        return 0
    else
        echo -e "${RED}✗ High disk usage: ${usage}%${NC}"
        return 1
    fi
}

# Check memory usage
check_memory() {
    echo -e "${YELLOW}Checking memory...${NC}"
    
    local total=$(free -m | awk 'NR==2 {print $2}')
    local used=$(free -m | awk 'NR==2 {print $3}')
    local percentage=$(( used * 100 / total ))
    local threshold=${MEMORY_THRESHOLD:-90}
    
    if [[ $percentage -lt $threshold ]]; then
        echo -e "${GREEN}✓ Memory usage: ${percentage}%${NC}"
        return 0
    else
        echo -e "${RED}✗ High memory usage: ${percentage}%${NC}"
        return 1
    fi
}

# Check SSL certificate
check_ssl() {
    echo -e "${YELLOW}Checking SSL certificate...${NC}"
    
    local domain=${DOMAIN:-localhost}
    
    if command -v openssl &> /dev/null; then
        local expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | \
            openssl x509 -noout -dates | grep notAfter | cut -d= -f2)
        
        if [[ -n "$expiry" ]]; then
            local expiry_date=$(date -d "$expiry" +%s)
            local today=$(date +%s)
            local days_left=$(( (expiry_date - today) / 86400 ))
            
            if [[ $days_left -gt 30 ]]; then
                echo -e "${GREEN}✓ SSL valid for ${days_left} days${NC}"
                return 0
            elif [[ $days_left -gt 0 ]]; then
                echo -e "${YELLOW}⚠ SSL expires in ${days_left} days${NC}"
                return 1
            else
                echo -e "${RED}✗ SSL certificate expired${NC}"
                return 1
            fi
        fi
    fi
    
    echo -e "${YELLOW}⚠ SSL check skipped${NC}"
    return 0
}

# Generate report
generate_report() {
    local checks=(
        "check_app_health"
        "check_database"
        "check_redis"
        "check_disk_space"
        "check_memory"
        "check_ssl"
    )
    
    local passed=0
    local failed=0
    local report_file="${SCRIPT_DIR}/../logs/health_report_$(date +%Y%m%d_%H%M%S).json"
    
    echo -e "\n${YELLOW}══════════════════════════════════════════${NC}"
    echo -e "${YELLOW}          HEALTH CHECK REPORT             ${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════${NC}"
    
    local report="{ \"timestamp\": \"$(date -Iseconds)\", \"checks\": ["
    
    for check in "${checks[@]}"; do
        echo -e "\n${YELLOW}Running: $check${NC}"
        
        if $check; then
            echo -e "${GREEN}✓ PASSED${NC}"
            report+="{\"check\":\"$check\",\"status\":\"passed\"},"
            passed=$((passed + 1))
        else
            echo -e "${RED}✗ FAILED${NC}"
            report+="{\"check\":\"$check\",\"status\":\"failed\"},"
            failed=$((failed + 1))
        fi
    done
    
    report="${report%,}]}"
    echo "$report" > "$report_file"
    
    echo -e "\n${YELLOW}══════════════════════════════════════════${NC}"
    echo -e "Summary: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
    echo -e "Report saved to: $report_file"
    echo -e "${YELLOW}══════════════════════════════════════════${NC}"
    
    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Continuous monitoring
monitor() {
    echo -e "${YELLOW}Starting continuous monitoring...${NC}"
    echo "Press Ctrl+C to stop"
    
    trap 'echo -e "\n${YELLOW}Monitoring stopped${NC}"; exit 0' INT
    
    while true; do
        clear
        echo -e "${YELLOW}══════════════════════════════════════════${NC}"
        echo -e "${YELLOW}      REAL-TIME MONITORING               ${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════${NC}"
        echo ""
        
        # Display metrics
        check_app_health
        check_database
        check_redis
        
        # Show Docker stats
        echo -e "\n${YELLOW}Docker Containers:${NC}"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        
        # Show system metrics
        echo -e "\n${YELLOW}System Metrics:${NC}"
        echo "CPU: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}')%"
        echo "Memory: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
        echo "Disk: $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"
        
        sleep 10
    done
}

# Main function
main() {
    load_config
    
    case "${1:-}" in
        "monitor")
            monitor
            ;;
        "report")
            generate_report
            ;;
        "check")
            check_app_health "$2"
            ;;
        *)
            echo "Usage: $0 {monitor|report|check [url]}"
            exit 1
            ;;
    esac
}

main "$@"