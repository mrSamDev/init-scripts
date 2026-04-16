#!/usr/bin/env bash

set -e

PROJECT_NAME="pimcore-demo"
REPO_URL="https://github.com/pimcore/demo.git"
REQUIRED_SERVICES=("docker" "docker-compose")

# Colors for output (disabled on Windows CMD)
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

detect_os() {
    case "$OSTYPE" in
        darwin*)
            OS="macos"
            ;;
        linux*)
            OS="linux"
            ;;
        msys*|win32*)
            OS="windows"
            ;;
        *)
            OS="unknown"
            ;;
    esac
    log_info "Detected OS: $OS ($OSTYPE)"
}

check_command() {
    local cmd=$1
    local install_hint=$2
    
    if command -v "$cmd" &> /dev/null; then
        local version=$("$cmd" --version 2>&1 | head -n 1)
        log_success "$cmd is installed: $version"
        return 0
    else
        log_error "$cmd is not installed"
        if [ -n "$install_hint" ]; then
            log_info "Install hint: $install_hint"
        fi
        return 1
    fi
}

check_docker_compose() {
    if command -v docker-compose &> /dev/null; then
        local version=$(docker-compose --version 2>&1)
        log_success "docker-compose is installed: $version"
        return 0
    elif docker compose version &> /dev/null; then
        local version=$(docker compose version 2>&1)
        log_success "Docker Compose plugin is installed: $version"
        return 0
    else
        log_error "Docker Compose is not installed (neither standalone nor plugin)"
        return 1
    fi
}

check_docker_running() {
    if docker info &> /dev/null; then
        log_success "Docker daemon is running"
        return 0
    else
        log_error "Docker daemon is not running"
        return 1
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    echo ""
    
    local missing=0

    if ! check_command "git" "macOS: brew install git | Linux: sudo apt install git | Windows: choco install git"; then
        missing=1
    fi

    if ! check_command "docker" "macOS: brew install --cask docker | Linux: sudo apt install docker.io | Windows: choco install docker-desktop"; then
        missing=1
    fi

    if ! check_docker_compose; then
        missing=1
    fi

    if ! check_docker_running; then
        log_info "Please start Docker Desktop (macOS/Windows) or 'sudo systemctl start docker' (Linux)"
        missing=1
    fi
    
    echo ""
    
    if [ $missing -eq 1 ]; then
        log_error "Some prerequisites are missing. Please install them and run the script again."
        exit 1
    fi
    
    log_success "All prerequisites are met!"
    echo ""
}

run_docker_compose() {
    # V2 plugin ships as "docker compose"; V1 standalone is "docker-compose"
    if docker compose version &> /dev/null; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

clone_project() {
    log_info "Cloning Pimcore demo project (branch: 2025.x)..."

    if [ ! -d "$PROJECT_NAME" ]; then
        git clone -b 2025.x "$REPO_URL" "$PROJECT_NAME"
        log_success "Project cloned successfully"
    else
        log_warning "Project directory already exists, skipping clone..."
    fi

    cd "$PROJECT_NAME"
}

# pimcore/platform-version uses "^2025.x-dev" which is invalid semver, and the
# PayPal bundle pulls in ecommerce-framework ^2.0 which has no stable release.
# These three patch_* functions fix constraints, drop the bundle, and strip its YAML.
patch_composer_json() {
    log_info "Patching composer.json version constraints..."

    if ! command -v python3 &> /dev/null; then
        log_error "python3 is required to patch composer.json but was not found"
        exit 1
    fi

    python3 - <<'PYEOF'
import json, sys

with open("composer.json", "r") as f:
    data = json.load(f)

req = data.get("require", {})

# "^2025.x-dev" is invalid semver, wildcard lets composer resolve it
if "pimcore/platform-version" in req:
    req["pimcore/platform-version"] = "*"

# Remove payment provider: its ^3.0 requires ecommerce-framework ^2.0
# which has no stable release, causing unsolvable constraints
req.pop("pimcore/payment-provider-paypal-smart-payment-button", None)

# Ensure all other pimcore/* use wildcards so composer can resolve freely
for pkg in list(req.keys()):
    if pkg.startswith("pimcore/") and pkg not in ("pimcore/platform-version",):
        req[pkg] = "*"

data["require"] = req

with open("composer.json", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("composer.json patched successfully")
PYEOF

    log_success "composer.json patched"
}

patch_bundles_php() {
    log_info "Removing PayPal bundle registration from bundles.php..."

    # Remove the use statement
    sed -i.bak '/PimcorePaymentProviderPayPalSmartPaymentButtonBundle/d' config/bundles.php
    rm -f config/bundles.php.bak

    log_success "bundles.php patched"
}

patch_ecommerce_yaml() {
    log_info "Removing PayPal payment_manager config from ecommerce YAML..."

    python3 - <<'PYEOF'
import re

path = "config/ecommerce/base-ecommerce.yaml"
with open(path, "r") as f:
    content = f.read()

# Remove the payment: provider: paypal block inside checkout_manager
content = re.sub(r'\s+payment:\s*\n\s+provider:\s*paypal\s*\n', '\n', content)

# Remove the entire payment_manager: block (up to the next top-level comment)
content = re.sub(
    r'    payment_manager:.*?(?=    # tracking manager)',
    '',
    content,
    flags=re.DOTALL
)

with open(path, "w") as f:
    f.write(content)

print("base-ecommerce.yaml patched successfully")
PYEOF

    log_success "ecommerce YAML patched"
}

setup_env() {
    log_info "Setting up environment file..."
    
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            cp .env.example .env
            log_success ".env file created from .env.example"
        else
            log_warning ".env.example not found, you may need to create .env manually"
        fi
    else
        log_info ".env file already exists"
    fi
}

start_containers() {
    log_info "Starting Docker containers..."
    run_docker_compose up -d
    log_success "Containers started"
}

wait_for_services() {
    log_info "Waiting for containers to initialize (this may take a minute)..."
    
    # More robust waiting - check if PHP container is responsive
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if run_docker_compose exec -T php php -v &> /dev/null; then
            log_success "PHP container is ready"
            return 0
        fi
        echo -ne "\r⏳ Waiting... attempt $attempt/$max_attempts"
        sleep 3
        ((attempt++))
    done
    
    echo ""
    log_warning "Container took longer than expected to start. Continuing anyway..."
}

install_pimcore() {
    log_info "Checking Pimcore installation..."

    if [ ! -f "var/config/system.yaml" ]; then
        log_info "Running composer install..."
        run_docker_compose exec -T php composer install --no-interaction --no-security-blocking
        log_success "Composer dependencies installed"

        log_info "Installing Pimcore..."
        run_docker_compose exec -T php vendor/bin/pimcore-install \
            --admin-username=admin \
            --admin-password=admin \
            --mysql-host-socket=db \
            --mysql-username=pimcore \
            --mysql-password=pimcore \
            --mysql-database=pimcore \
            --no-interaction

        log_success "Pimcore installed successfully"
    else
        log_info "Pimcore is already installed, skipping installation..."
    fi
}

install_assets() {
    log_info "Installing assets..."
    run_docker_compose exec -T php bin/console assets:install --symlink --relative
    log_success "Assets installed"
}

clear_cache() {
    log_info "Clearing cache..."
    run_docker_compose exec -T php bin/console cache:clear
    log_success "Cache cleared"
}

show_completion_message() {
    echo ""
    echo "================================================================="
    log_success "Pimcore is ready!"
    echo "================================================================="
    echo ""
    echo "👉 Access URL: http://localhost/admin"
    echo "👤 Username:   admin"
    echo "🔑 Password:   admin"
    echo ""
    echo "To stop the containers:"
    echo "  cd $PROJECT_NAME"
    echo "  run_docker_compose down"
    echo ""
    echo "To start again:"
    echo "  run_docker_compose up -d"
    echo ""
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    echo ""
    echo "================================================================="
    echo "🚀 Pimcore Docker Setup Script"
    echo "================================================================="
    echo ""
    
    detect_os
    check_prerequisites
    clone_project
    patch_composer_json
    patch_bundles_php
    patch_ecommerce_yaml
    setup_env
    start_containers
    wait_for_services
    install_pimcore
    install_assets
    clear_cache
    show_completion_message
}

# Run main function
main "$@"
