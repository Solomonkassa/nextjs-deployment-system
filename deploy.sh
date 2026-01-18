#!/usr/bin/env bash

# =============================================================================
# Advanced Next.js Production Deployment Script
# Version: 2.0.0
# Author: Solomon Kassa
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(dirname "$SCRIPT_DIR")"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly DEPLOY_LOG="${ROOT_DIR}/logs/deploy_${TIMESTAMP}.log"
readonly LOCK_FILE="/tmp/nextjs_deploy.lock"

# Environment variables
ENVIRONMENT=${ENVIRONMENT:-"production"}
APP_NAME=${APP_NAME:-"nextjs-app"}
DOCKER_REGISTRY=${DOCKER_REGISTRY:-"ghcr.io"}
GITHUB_SHA=${GITHUB_SHA:-"local"}
MAX_RETRIES=3
HEALTH_CHECK_TIMEOUT=300
BACKUP_RETENTION_DAYS=7

# Load environment specific config
load_environment_config() {
    local env_file="${ROOT_DIR}/config/environment/.env.${ENVIRONMENT}"
    
    if [[ -f "$env_file" ]]; then
        export $(grep -v '^#' "$env_file" | xargs)
        echo -e "${GREEN}✓ Loaded environment config: ${ENVIRONMENT}${NC}"
    else
        echo -e "${YELLOW}⚠ No environment config found for ${ENVIRONMENT}${NC}"
    fi
}

# Initialize logging
init_logging() {
    mkdir -p "${ROOT_DIR}/logs"
    mkdir -p "${ROOT_DIR}/backups"
    
    exec 3>&1 4>&2
    trap 'exec 2>&4 1>&3' 0 1 2 3
    exec 1> >(tee -a "$DEPLOY_LOG") 2>&1
    
    echo "=========================================="
    echo "Deployment Started: $(date)"
    echo "Environment: $ENVIRONMENT"
    echo "Commit SHA: $GITHUB_SHA"
    echo "=========================================="
}

# Check prerequisites
check_prerequisites() {
    local missing_deps=()
    
    echo -e "${BLUE}🔍 Checking prerequisites...${NC}"
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    else
        DOCKER_VERSION=$(docker --version | cut -d ' ' -f 3 | cut -d ',' -f 1)
        echo -e "${GREEN}✓ Docker $DOCKER_VERSION${NC}"
    fi
    
    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        missing_deps+=("docker-compose")
    else
        echo -e "${GREEN}✓ Docker Compose${NC}"
    fi
    
    # Check Node.js
    if ! command -v node &> /dev/null; then
        missing_deps+=("node")
    else
        NODE_VERSION=$(node --version)
        echo -e "${GREEN}✓ Node $NODE_VERSION${NC}"
    fi
    
    # Check required ports
    local required_ports=(80 443 3000 5432 6379)
    for port in "${required_ports[@]}"; do
        if lsof -i :$port > /dev/null 2>&1; then
            echo -e "${YELLOW}⚠ Port $port is in use${NC}"
        fi
    done
    
    # Check disk space
    local disk_usage=$(df -h . | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        echo -e "${RED}✗ Disk usage is above 90%${NC}"
        exit 1
    fi
    
    # Check memory
    local free_memory=$(free -m | awk 'NR==2 {print $4}')
    if [[ $free_memory -lt 1024 ]]; then
        echo -e "${YELLOW}⚠ Low memory available: ${free_memory}MB${NC}"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}✗ Missing dependencies: ${missing_deps[*]}${NC}"
        exit 1
    fi
}

# Acquire deployment lock
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null; then
            echo -e "${RED}✗ Another deployment is running (PID: $pid)${NC}"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
    echo -e "${GREEN}✓ Deployment lock acquired${NC}"
}

# Backup current deployment
backup_current() {
    echo -e "${BLUE}💾 Creating backup...${NC}"
    
    local backup_dir="${ROOT_DIR}/backups/backup_${TIMESTAMP}"
    mkdir -p "$backup_dir"
    
    # Backup Docker volumes
    if docker volume ls -q | grep -q "${APP_NAME}"; then
        docker run --rm \
            -v "${APP_NAME}_data:/data" \
            -v "$backup_dir:/backup" \
            alpine tar czf /backup/data_volume.tar.gz -C /data . 2>/dev/null || true
    fi
    
    # Backup environment files
    cp -r "${ROOT_DIR}/config" "$backup_dir/" 2>/dev/null || true
    cp "${ROOT_DIR}/.env*" "$backup_dir/" 2>/dev/null || true
    
    # Clean old backups
    find "${ROOT_DIR}/backups" -name "backup_*" -type d -mtime +$BACKUP_RETENTION_DAYS -exec rm -rf {} +
    
    echo -e "${GREEN}✓ Backup created: $backup_dir${NC}"
}

# Build Docker image
build_docker_image() {
    echo -e "${BLUE}🐳 Building Docker image...${NC}"
    
    local dockerfile="docker/Dockerfile"
    local build_args=""
    
    if [[ "$ENVIRONMENT" == "development" ]]; then
        dockerfile="docker/Dockerfile.dev"
        build_args="--target development"
    fi
    
    # Multi-stage build with caching
    docker build \
        -f "$dockerfile" \
        -t "${DOCKER_REGISTRY}/${APP_NAME}:${GITHUB_SHA}" \
        -t "${DOCKER_REGISTRY}/${APP_NAME}:latest" \
        --build-arg ENVIRONMENT="$ENVIRONMENT" \
        --build-arg GITHUB_SHA="$GITHUB_SHA" \
        --cache-from "${DOCKER_REGISTRY}/${APP_NAME}:latest" \
        $build_args \
        "$ROOT_DIR"
    
    # Scan for vulnerabilities
    if command -v trivy &> /dev/null; then
        echo -e "${CYAN}🔒 Scanning for vulnerabilities...${NC}"
        trivy image --exit-code 0 --severity HIGH,CRITICAL \
            "${DOCKER_REGISTRY}/${APP_NAME}:${GITHUB_SHA}"
    fi
    
    echo -e "${GREEN}✓ Docker image built successfully${NC}"
}

# Push to registry
push_to_registry() {
    if [[ "$ENVIRONMENT" == "production" ]]; then
        echo -e "${BLUE}📤 Pushing to registry...${NC}"
        
        # Login to registry if credentials exist
        if [[ -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
            echo "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" \
                -u "$DOCKER_USERNAME" --password-stdin
        fi
        
        docker push "${DOCKER_REGISTRY}/${APP_NAME}:${GITHUB_SHA}"
        docker push "${DOCKER_REGISTRY}/${APP_NAME}:latest"
        
        echo -e "${GREEN}✓ Images pushed to registry${NC}"
    fi
}

# Run database migrations
run_migrations() {
    echo -e "${BLUE}🔄 Running database migrations...${NC}"
    
    local retry_count=0
    local max_retries=5
    
    while [[ $retry_count -lt $max_retries ]]; do
        if docker-compose -f "${ROOT_DIR}/docker/docker-compose.yml" \
            run --rm app npx prisma migrate deploy; then
            echo -e "${GREEN}✓ Migrations completed successfully${NC}"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        echo -e "${YELLOW}⚠ Migration attempt $retry_count failed, retrying...${NC}"
        sleep 5
    done
    
    echo -e "${RED}✗ Migrations failed after $max_retries attempts${NC}"
    return 1
}

# Deploy application
deploy_application() {
    echo -e "${BLUE} 🚀 Deploying application...${NC}"
    
    # Stop existing containers
    docker-compose -f "${ROOT_DIR}/docker/docker-compose.yml" down --timeout 30
    
    # Pull latest images
    docker-compose -f "${ROOT_DIR}/docker/docker-compose.yml" pull
    
    # Start services
    docker-compose -f "${ROOT_DIR}/docker/docker-compose.yml" up -d \
        --remove-orphans \
        --force-recreate \
        --scale app=3
    
    echo -e "${GREEN}✓ Application deployed${NC}"
}

# Health check
health_check() {
    echo -e "${BLUE}🏥 Performing health check...${NC}"
    
    local start_time=$(date +%s)
    local healthy=false
    
    while [[ $(($(date +%s) - start_time)) -lt $HEALTH_CHECK_TIMEOUT ]]; do
        # Check main app
        local response=$(curl -s -o /dev/null -w "%{http_code}" \
            http://localhost:3000/api/health || echo "000")
        
        # Check database
        local db_status=$(docker-compose -f "${ROOT_DIR}/docker/docker-compose.yml" \
            exec -T db pg_isready -U postgres 2>/dev/null && echo "ready" || echo "down")
        
        # Check Redis
        local redis_status=$(docker-compose -f "${ROOT_DIR}/docker/docker-compose.yml" \
            exec -T redis redis-cli ping 2>/dev/null | grep -q PONG && echo "ready" || echo "down")
        
        if [[ "$response" == "200" && "$db_status" == "ready" && "$redis_status" == "ready" ]]; then
            healthy=true
            break
        fi
        
        echo -e "${YELLOW}⏳ Waiting for services to be healthy...${NC}"
        echo "  App: $response, DB: $db_status, Redis: $redis_status"
        sleep 10
    done
    
    if [[ "$healthy" == true ]]; then
        echo -e "${GREEN}✓ All services are healthy${NC}"
        
        # Run smoke tests
        run_smoke_tests
        
        return 0
    else
        echo -e "${RED}✗ Health check failed${NC}"
        return 1
    fi
}

# Run smoke tests
run_smoke_tests() {
    echo -e "${BLUE}🧪 Running smoke tests...${NC}"
    
    local tests_passed=0
    local tests_failed=0
    
    # Test endpoints
    local endpoints=(
        "/api/health"
        "/api/status"
        "/"
        "/api/users/me"
    )
    
    for endpoint in "${endpoints[@]}"; do
        if curl -s -f "http://localhost:3000${endpoint}" > /dev/null 2>&1; then
            echo -e "${GREEN}  ✓ $endpoint${NC}"
            tests_passed=$((tests_passed + 1))
        else
            echo -e "${RED}  ✗ $endpoint${NC}"
            tests_failed=$((tests_failed + 1))
        fi
    done
    
    # Check response time
    local response_time=$(curl -s -w "%{time_total}" -o /dev/null http://localhost:3000/api/health)
    if (( $(echo "$response_time < 1.0" | bc -l) )); then
        echo -e "${GREEN}  ✓ Response time: ${response_time}s${NC}"
    else
        echo -e "${YELLOW}  ⚠ Response time: ${response_time}s (slow)${NC}"
    fi
    
    echo -e "${BLUE}📊 Test results: $tests_passed passed, $tests_failed failed${NC}"
}

# Cleanup
cleanup() {
    echo -e "${BLUE}🧹 Cleaning up...${NC}"
    
    # Remove old Docker images
    docker image prune -f --filter "until=24h"
    
    # Remove stopped containers
    docker container prune -f
    
    # Remove unused volumes
    docker volume prune -f
    
    # Remove old deployment logs
    find "${ROOT_DIR}/logs" -name "*.log" -mtime +30 -delete
    
    echo -e "${GREEN}✓ Cleanup completed${NC}"
}

# Rollback on failure
rollback() {
    echo -e "${RED}🚨 Rolling back deployment...${NC}"
    
    # Find latest backup
    local latest_backup=$(find "${ROOT_DIR}/backups" -name "backup_*" -type d | sort -r | head -1)
    
    if [[ -n "$latest_backup" ]]; then
        echo -e "${YELLOW}Restoring from backup: $latest_backup${NC}"
        
        # Stop current deployment
        docker-compose -f "${ROOT_DIR}/docker/docker-compose.yml" down
        
        # Restore volumes
        if [[ -f "${latest_backup}/data_volume.tar.gz" ]]; then
            docker run --rm \
                -v "${APP_NAME}_data:/data" \
                -v "${latest_backup}:/backup" \
                alpine tar xzf /backup/data_volume.tar.gz -C /data 2>/dev/null || true
        fi
        
        # Restart previous version
        docker-compose -f "${ROOT_DIR}/docker/docker-compose.yml" up -d
        
        echo -e "${GREEN}✓ Rollback completed${NC}"
    else
        echo -e "${RED}✗ No backup found for rollback${NC}"
    fi
}

# Send notifications
send_notification() {
    local status=$1
    local message=$2
    
    # Slack notification
    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"Deployment ${status}: ${APP_NAME} (${ENVIRONMENT})\n${message}\nSHA: ${GITHUB_SHA}\"}" \
            "$SLACK_WEBHOOK_URL" > /dev/null 2>&1 || true
    fi
    
    # Email notification
    if [[ -n "${ALERT_EMAIL:-}" && "$status" == "FAILED" ]]; then
        echo "Deployment failed for ${APP_NAME} (${ENVIRONMENT})" | \
            mail -s "Deployment Alert: ${APP_NAME}" "$ALERT_EMAIL" || true
    fi
    
    echo -e "${GREEN}✓ Notifications sent${NC}"
}

# Main deployment function
main() {
    echo -e "${MAGENTA}==========================================${NC}"
    echo -e "${MAGENTA}    Next.js Deployment System v2.0.0      ${NC}"
    echo -e "${MAGENTA}==========================================${NC}"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -a|--app-name)
                APP_NAME="$2"
                shift 2
                ;;
            --sha)
                GITHUB_SHA="$2"
                shift 2
                ;;
            --skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Initialize
    init_logging
    load_environment_config
    acquire_lock
    
    # Deployment steps
    local steps=(
        "check_prerequisites"
        "backup_current"
        "build_docker_image"
        "push_to_registry"
        "run_migrations"
        "deploy_application"
        "health_check"
        "cleanup"
    )
    
    local failed=false
    
    for step in "${steps[@]}"; do
        echo -e "\n${CYAN}▶ Running: ${step}${NC}"
        
        if $step; then
            echo -e "${GREEN}✓ ${step} completed${NC}"
        else
            echo -e "${RED}✗ ${step} failed${NC}"
            failed=true
            break
        fi
    done
    
    # Handle deployment result
    if [[ "$failed" == true ]]; then
        echo -e "\n${RED}==========================================${NC}"
        echo -e "${RED}         DEPLOYMENT FAILED                ${NC}"
        echo -e "${RED}==========================================${NC}"
        
        rollback
        send_notification "FAILED" "Deployment failed at step: $step"
        
        # Exit with error code
        exit 1
    else
        echo -e "\n${GREEN}==========================================${NC}"
        echo -e "${GREEN}      DEPLOYMENT SUCCESSFUL              ${NC}"
        echo -e "${GREEN}==========================================${NC}"
        
        send_notification "SUCCESS" "Deployment completed successfully"
        
        # Show deployment info
        echo -e "\n${BLUE}📊 Deployment Summary:${NC}"
        echo "  Environment: $ENVIRONMENT"
        echo "  Version: $GITHUB_SHA"
        echo "  Timestamp: $(date)"
        echo "  Log file: $DEPLOY_LOG"
        
        exit 0
    fi
}

# Show help
show_help() {
    cat << EOF
Usage: ./deploy.sh [OPTIONS]

Next.js Production Deployment Script

Options:
  -e, --environment ENV   Deployment environment (production, staging, development)
  -a, --app-name NAME     Application name
  --sha COMMIT_SHA        Git commit SHA
  --skip-backup           Skip backup creation
  --skip-tests           Skip smoke tests
  -h, --help             Show this help message

Examples:
  ./deploy.sh --environment production
  ./deploy.sh --environment staging --app-name myapp
EOF
}

# Run main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi