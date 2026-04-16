#!/usr/bin/env bash

set -e

SCRIPT_VERSION="v1.0.2"
PROJECT_NAME="my-pimcore-10"
PIMCORE_VERSION="10.6.9"
SKELETON_VERSION="v10.2.6"
PHP_IMAGE="pimcore/pimcore:php8.1-latest"
HOST_PORT=80

# Colors for output
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

# =============================================================================
# OS Detection
# =============================================================================

detect_os() {
    case "$OSTYPE" in
        darwin*)  OS="macos" ;;
        linux*)   OS="linux" ;;
        msys*|win32*) OS="windows" ;;
        *)        OS="unknown" ;;
    esac
    log_info "Detected OS: $OS ($OSTYPE)"
}

# =============================================================================
# Prerequisites
# =============================================================================

check_command() {
    local cmd=$1
    local hint=$2
    if command -v "$cmd" &>/dev/null; then
        local ver; ver=$("$cmd" --version 2>&1 | head -n 1)
        log_success "$cmd is installed: $ver"
        return 0
    else
        log_error "$cmd is not installed"
        [ -n "$hint" ] && log_info "Install hint: $hint"
        return 1
    fi
}

check_docker_compose() {
    if command -v docker-compose &>/dev/null; then
        log_success "docker-compose is installed: $(docker-compose --version 2>&1)"
        return 0
    elif docker compose version &>/dev/null; then
        log_success "Docker Compose plugin is installed: $(docker compose version 2>&1)"
        return 0
    else
        log_error "Docker Compose is not installed (neither standalone nor plugin)"
        return 1
    fi
}

check_docker_running() {
    if docker info &>/dev/null; then
        log_success "Docker daemon is running"
        return 0
    else
        log_error "Docker daemon is not running"
        log_info "Please start Docker Desktop (macOS/Windows) or run: sudo systemctl start docker (Linux)"
        return 1
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    echo ""

    local missing=0

    check_command "git"    "macOS: brew install git | Linux: sudo apt install git -y"          || missing=1
    check_command "docker" "macOS: brew install --cask docker | Linux: sudo apt install docker.io -y" || missing=1
    check_docker_compose || missing=1
    check_docker_running  || missing=1

    if ! command -v python3 &>/dev/null; then
        log_error "python3 is not installed (required for composer.json patching)"
        log_info "Install hint: macOS: brew install python3 | Linux: sudo apt install python3 -y"
        missing=1
    else
        log_success "python3 is installed: $(python3 --version 2>&1)"
    fi

    echo ""
    if [ $missing -eq 1 ]; then
        log_error "Some prerequisites are missing. Please install them and run the script again."
        exit 1
    fi
    log_success "All prerequisites are met!"
    echo ""
}

# =============================================================================
# Step 2 — Create project skeleton (no-install mode)
# Runs composer create-project inside the official PHP image.
# No local PHP or Composer needed.
# =============================================================================

create_skeleton() {
    log_info "Creating Pimcore $PIMCORE_VERSION skeleton project..."

    if [ -d "$PROJECT_NAME" ]; then
        log_warning "Directory '$PROJECT_NAME' already exists — skipping skeleton creation."
        cd "$PROJECT_NAME"
        return 0
    fi

    docker run -u "$(id -u):$(id -g)" --rm \
        -v "$(pwd):/var/www/html" \
        "$PHP_IMAGE" \
        composer create-project \
            --stability=stable \
            --no-interaction \
            --no-install \
            "pimcore/skeleton:$SKELETON_VERSION" \
            "$PROJECT_NAME"

    log_success "Skeleton created in $PROJECT_NAME/"
    cd "$PROJECT_NAME"
}

# =============================================================================
# Step 3 — Patch composer.json
#   • Disable security advisory blocking (Pimcore 10.x has 60+ known CVEs)
#   • Pin pimcore/pimcore to exactly 10.6.9
# =============================================================================

patch_composer_json() {
    log_info "Patching composer.json (disabling security block, pinning to $PIMCORE_VERSION)..."

    python3 - <<PYEOF
import json

with open("composer.json", "r") as f:
    data = json.load(f)

# Disable Composer audit blocking so 10.x installs without being rejected
data.setdefault("config", {})
data["config"]["audit"] = {
    "abandoned": "ignore",
    "block-insecure": False
}

# Pin pimcore/pimcore to the exact target version
data.setdefault("require", {})
data["require"]["pimcore/pimcore"] = "$PIMCORE_VERSION"

with open("composer.json", "w") as f:
    json.dump(data, f, indent=4)
    f.write("\n")

print("composer.json patched successfully")
PYEOF

    log_success "composer.json patched (pimcore/pimcore pinned to $PIMCORE_VERSION, audit.block-insecure disabled)"
    log_warning "Security advisory checking is DISABLED — local dev only. Never use block-insecure:false in production."
}

# =============================================================================
# Step 4 — Install Composer dependencies
# Runs inside the official PHP Docker image — no local PHP needed.
# =============================================================================

install_composer_deps() {
    if [ -d "vendor" ] && [ -f "vendor/autoload.php" ]; then
        log_info "vendor/ already exists — skipping composer install"
        return 0
    fi

    log_info "Installing Composer dependencies inside Docker (no local PHP required)..."

    docker run -u "$(id -u):$(id -g)" --rm \
        -v "$(pwd):/var/www/html" \
        "$PHP_IMAGE" \
        composer install --no-interaction --working-dir=/var/www/html

    log_success "Composer dependencies installed"
}

# =============================================================================
# Step 5 — Set correct user ID in docker-compose.yaml
# Prevents file permission mismatches between host and container.
# =============================================================================

patch_docker_compose_user() {
    log_info "Setting container user to host UID:GID ($(id -u):$(id -g))..."

    local compose_file=""
    [ -f "docker-compose.yaml" ] && compose_file="docker-compose.yaml"
    [ -f "docker-compose.yml"  ] && compose_file="docker-compose.yml"

    if [ -z "$compose_file" ]; then
        log_warning "docker-compose file not found — skipping user patch"
        return 0
    fi

    if grep -q "#user:" "$compose_file"; then
        sed -i.bak "s|#user: '1000:1000'|user: '$(id -u):$(id -g)'|g" "$compose_file"
        rm -f "${compose_file}.bak"
        log_success "docker-compose user set to $(id -u):$(id -g)"
    else
        log_info "No '#user:' placeholder found in $compose_file — skipping"
    fi
}

# =============================================================================
# Step 6 — Port conflict resolution (auto-detect and fallback)
# =============================================================================

check_port_in_use() {
    local port=$1
    if command -v lsof &>/dev/null; then
        lsof -i TCP:"$port" -sTCP:LISTEN -t &>/dev/null
    elif command -v ss &>/dev/null; then
        ss -tlnp | grep -q ":$port "
    else
        (echo >/dev/tcp/localhost/"$port") &>/dev/null
    fi
}

setup_port() {
    log_info "Checking port availability..."

    if check_port_in_use 80; then
        log_warning "Port 80 is already in use. Searching for an available port..."

        for try_port in 8080 8081 8082 8083 8090 9000; do
            if ! check_port_in_use "$try_port"; then
                HOST_PORT=$try_port
                break
            fi
        done

        if [ "$HOST_PORT" -eq 80 ]; then
            log_error "Could not find a free port (tried 8080 8081 8082 8083 8090 9000). Free a port and retry."
            exit 1
        fi

        log_info "Port 80 is taken — patching docker-compose to use port $HOST_PORT"

        local compose_file=""
        [ -f "docker-compose.yaml" ] && compose_file="docker-compose.yaml"
        [ -f "docker-compose.yml"  ] && compose_file="docker-compose.yml"

        if [ -n "$compose_file" ]; then
            # Replace any existing 80:80 binding with HOST_PORT:80
            sed -i.bak "s/\"80:80\"/\"$HOST_PORT:80\"/g" "$compose_file"
            sed -i.bak "s/'80:80'/'$HOST_PORT:80'/g" "$compose_file"
            rm -f "${compose_file}.bak"
        fi
    fi

    log_success "Web server will be available on port $HOST_PORT"
}

# =============================================================================
# Step 7 — Start Docker containers
# =============================================================================

run_docker_compose() {
    if docker compose version &>/dev/null; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

start_containers() {
    log_info "Starting Docker containers..."
    run_docker_compose up -d
    log_success "Containers started"

    log_info "Verifying all containers are running..."
    run_docker_compose ps
}

# =============================================================================
# Wait for PHP and DB to be ready before installing
# =============================================================================

wait_for_services() {
    log_info "Waiting for PHP container to be ready..."

    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if run_docker_compose exec -T php php -v &>/dev/null; then
            log_success "PHP container is ready"
            break
        fi
        echo -ne "\r⏳ Waiting for PHP... attempt $attempt/$max_attempts"
        sleep 3
        ((attempt++))
    done

    if [ $attempt -gt $max_attempts ]; then
        echo ""
        log_warning "PHP container took longer than expected. Continuing anyway..."
    fi

    log_info "Waiting for database to be ready (checking from PHP container)..."
    attempt=1

    while [ $attempt -le $max_attempts ]; do
        if run_docker_compose exec -T php php -r \
            "new PDO('mysql:host=db;port=3306;dbname=pimcore', 'pimcore', 'pimcore');" \
            &>/dev/null; then
            log_success "Database is ready"
            return 0
        fi
        echo -ne "\r⏳ Waiting for DB... attempt $attempt/$max_attempts"
        sleep 3
        ((attempt++))
    done

    echo ""
    log_warning "Database took longer than expected to start. Continuing anyway..."
}

# =============================================================================
# Step 8 — Run Pimcore installer
# =============================================================================

install_pimcore() {
    log_info "Checking Pimcore installation..."

    if [ -f "var/config/system.yaml" ] || [ -f "var/config/system.yml" ]; then
        log_info "Pimcore is already installed — skipping."
        return 0
    fi

    log_info "Preparing var/ directory..."
    run_docker_compose exec -T -u root php bash -c \
        "mkdir -p /var/www/html/var/log /var/www/html/var/cache && chmod -R 777 /var/www/html/var"

    log_info "Running Pimcore installer (this can take 5–15 minutes)..."
    run_docker_compose exec -T -u root php vendor/bin/pimcore-install \
        --mysql-host-socket=db \
        --mysql-port=3306 \
        --mysql-username=pimcore \
        --mysql-password=pimcore \
        --mysql-database=pimcore \
        --admin-username=admin \
        --admin-password=admin \
        --no-interaction

    log_success "Pimcore installed successfully"
}

# =============================================================================
# Step 9 — Fix CsvFormulaFormatter type mismatch
# Pimcore 10.6.9's CsvFormulaFormatter declares string $field but league/csv
# newer versions changed it to mixed. Downgrade to a compatible version.
# This is saved to composer.lock so all team members get the fix automatically.
# =============================================================================

fix_league_csv() {
    log_info "Pinning league/csv to ^9.7.4 (Pimcore 10.6.9 compatibility fix)..."

    run_docker_compose exec -T php bash -c \
        "COMPOSER_ALLOW_SUPERUSER=1 composer require league/csv:'^9.7.4' --no-audit --no-interaction"

    log_success "league/csv pinned to ^9.7.4 (fix saved to composer.lock)"
}

# =============================================================================
# Fix file permissions inside the container
# =============================================================================

fix_permissions() {
    log_info "Fixing file permissions..."
    run_docker_compose exec -T -u root php bash -c \
        "mkdir -p /var/www/html/var/log && chown -R www-data:www-data /var/www/html/var && chmod -R 775 /var/www/html/var"
    log_success "Permissions fixed"
}

# =============================================================================
# Step 10 — Clear cache
# =============================================================================

clear_cache() {
    log_info "Clearing cache..."
    run_docker_compose exec -T php bin/console cache:clear
    log_success "Cache cleared"
}

# =============================================================================
# Completion message
# =============================================================================

show_completion_message() {
    echo ""
    echo "================================================================="
    log_success "Pimcore $PIMCORE_VERSION is ready!"
    echo "================================================================="
    echo ""
    echo "👉 Access URL: http://localhost:${HOST_PORT}/admin"
    echo "👤 Username:   admin"
    echo "🔑 Password:   admin"
    echo ""
    echo "⚠️  Change the admin password after your first login."
    echo ""
    echo "Daily commands (run inside $PROJECT_NAME/):"
    echo "  docker compose up -d          # Start containers"
    echo "  docker compose down           # Stop containers"
    echo "  docker compose ps             # Check status"
    echo "  docker compose exec php bash  # Shell into PHP container"
    echo "  docker compose exec php bin/console cache:clear"
    echo ""
    echo "Security note:"
    echo "  Run 'docker compose exec php bash -c \"composer audit\"' to review CVEs."
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "================================================================="
    echo "🚀 Pimcore $PIMCORE_VERSION Docker Setup (Script $SCRIPT_VERSION)"
    echo "================================================================="
    echo ""

    detect_os
    check_prerequisites   # verify git, docker, docker compose, python3
    create_skeleton       # Step 2: composer create-project --no-install (inside Docker)
    patch_composer_json   # Step 3: pin 10.6.9, disable security block
    install_composer_deps # Step 4: composer install (inside Docker)
    patch_docker_compose_user # Step 5: set user UID:GID
    setup_port            # Step 6: auto-detect port conflict
    start_containers      # Step 7: docker compose up -d
    wait_for_services     #         wait for PHP + DB
    fix_permissions       #         chown var/ to www-data before install
    install_pimcore       # Step 8: vendor/bin/pimcore-install
    fix_league_csv        # Step 9: downgrade league/csv to ^9.7.4
    clear_cache           # Step 10: bin/console cache:clear
    show_completion_message
}

main "$@"
