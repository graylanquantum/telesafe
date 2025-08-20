#!/usr/bin/env bash

# ==============================================================================
# TELESAFE TERMINAL DEPLOYER & DASHBOARD (Robust Docker Detection)
# ==============================================================================

set -euo pipefail

REPO_URL="https://github.com/graylanquantum/telesafe.git"
APP_DIR="$HOME/telesafe_app"
IMAGE_NAME="telesafe_image"
CONTAINER_NAME="telesafe_container"
NETWORK="telesafe_net"
ENV_PATH="$HOME/.telesafe.env"
LOG_PATH="$HOME/telesafe_terminal.log"
DOCKER_REQUIRED_VERSION="20.10.0"
IPTABLES_REQUIRED_VERSION="1.8"

function color()   { echo -en "\033[$1m"; }
function nocolor() { echo -en "\033[0m"; }
function info()    { color 1; echo "[INFO]"   "$*"; nocolor; }
function warn()    { color 33; echo "[WARN]"  "$*"; nocolor; }
function error()   { color 31; echo "[ERROR]" "$*"; nocolor; }
function success() { color 32; echo "[OK]"    "$*"; nocolor; }
function header()  { color 36; echo -e "\n========== $* ==========\n"; nocolor; }

exec > >(tee -a "$LOG_PATH") 2>&1

trap 'error "An error occurred. See $LOG_PATH for details." ; exit 1' ERR

if [[ $EUID -eq 0 ]]; then
  error "Do NOT run this script as root! Use your regular user."
  exit 2
fi

if ! sudo -v; then
  error "You need passwordless sudo or sudo privileges to run this script."
  exit 2
fi

function version_ge() {
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

function ensure_docker_installed() {
  header "Dependency Check and Install"
  sudo apt-get update

  # Install Docker if missing/old
  if ! command -v docker &>/dev/null || ! version_ge "$(docker --version | awk '{print $3}' | sed 's/,//')" "$DOCKER_REQUIRED_VERSION"; then
    info "Docker not found or too old. Installing Docker..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc || true
    sudo apt-get install -y ca-certificates curl gnupg lsb-release iptables dnsutils git
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable docker
    sudo systemctl start docker
    sleep 3
  fi

  # Docker validation
  if ! command -v docker &>/dev/null; then
    error "Docker did not install correctly! Please check above for errors, log out/in, and try again."
    exit 1
  fi

  if ! docker info &>/dev/null; then
    error "Docker daemon not running or permission denied! Try 'sudo systemctl restart docker', or log out/in for group change."
    exit 1
  fi

  success "Docker is installed and available: $(docker --version)"

  # iptables check
  if ! command -v iptables &>/dev/null || ! version_ge "$(iptables --version | awk '{print $2}')" "$IPTABLES_REQUIRED_VERSION"; then
    info "Installing iptables..."
    sudo apt-get install -y iptables
  fi

  # dnsutils
  if ! command -v dig &>/dev/null; then
    info "Installing dnsutils for DNS resolution."
    sudo apt-get install -y dnsutils
  fi

  # git
  if ! command -v git &>/dev/null; then
    info "Installing git."
    sudo apt-get install -y git
  fi

  success "All dependencies installed and up to date."
}

function configure_docker_user() {
  header "Docker Group Configuration"
  if ! groups $USER | grep -qw docker; then
    info "Adding $USER to docker group."
    sudo usermod -aG docker $USER
    warn "You have been added to the docker group."
    warn "Please log out and back in, then re-run this script to continue installation."
    exit 0
  fi
  if ! docker info &>/dev/null; then
    error "Docker group not active. Please log out/in or run: newgrp docker"
    exit 1
  fi
  success "Docker group is active for $USER."
}

function prep_network() {
  header "Docker Network Preparation"
  if ! command -v docker &>/dev/null; then
    error "Docker is not available in your \$PATH. Please log out/in, then retry."
    exit 1
  fi
  if ! docker network ls | grep -qw "$NETWORK"; then
    info "Creating Docker network: $NETWORK"
    docker network create "$NETWORK"
    success "Network $NETWORK created."
  else
    info "Network $NETWORK already exists."
  fi
}

function prompt_and_save_api_key() {
  header "API Key Secure Input"
  if [ -f "$ENV_PATH" ]; then
    info "OPENAI_API_KEY already set in $ENV_PATH"
    return
  fi
  while true; do
    echo -n "Enter your OPENAI_API_KEY (input hidden): "
    stty -echo
    read OPENAI_API_KEY
    stty echo
    echo
    if [[ -z "$OPENAI_API_KEY" ]]; then
      warn "API key cannot be empty. Please try again."
      continue
    fi
    echo "OPENAI_API_KEY=$OPENAI_API_KEY" > "$ENV_PATH"
    chmod 600 "$ENV_PATH"
    success "API key saved securely to $ENV_PATH (permissions 600, owner only)."
    break
  done
}

function build_app() {
  header "Cloning and Building App"
  rm -rf "$APP_DIR"
  info "Cloning telesafe repository..."
  git clone "$REPO_URL" "$APP_DIR"
  cd "$APP_DIR"
  info "Building Docker image: $IMAGE_NAME"
  docker build -t "$IMAGE_NAME" .
  cd -
  success "Build complete."
}

function run_container() {
  header "Deploying Container"
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  docker run -d --name "$CONTAINER_NAME" \
    --network "$NETWORK" \
    --restart unless-stopped \
    --env-file "$ENV_PATH" \
    "$IMAGE_NAME"
  success "Container $CONTAINER_NAME is running."
}

function restrict_to_openai() {
  header "Applying Egress Firewall (OpenAI only)"
  CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")
  if [[ -z "$CONTAINER_IP" ]]; then
    error "Could not get container IP."
    exit 1
  fi
  # Remove previous rules for this container
  sudo iptables -D FORWARD -s $CONTAINER_IP -j DROP 2>/dev/null || true
  sudo iptables -D FORWARD -s $CONTAINER_IP -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
  sudo iptables -D FORWARD -s $CONTAINER_IP -p udp --dport 53 -j ACCEPT 2>/dev/null || true
  # Allow DNS
  sudo iptables -I FORWARD -s $CONTAINER_IP -p udp --dport 53 -j ACCEPT
  # Allow OpenAI completions endpoint
  OPENAI_IPS=$(dig +short api.openai.com | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
  if [[ -z "$OPENAI_IPS" ]]; then
    error "Could not resolve api.openai.com!"
    exit 1
  fi
  for IP in $OPENAI_IPS; do
    sudo iptables -I FORWARD -s $CONTAINER_IP -d $IP -p tcp --dport 443 -j ACCEPT
  done
  # Block everything else
  sudo iptables -A FORWARD -s $CONTAINER_IP -j DROP
  success "Egress firewall active! $CONTAINER_NAME can only access OpenAI completions endpoint."
}

function show_stats() {
  header "Live Resource Stats (Press Ctrl+C to exit)"
  docker stats --no-stream=false --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}" $CONTAINER_NAME
}

function show_logs() {
  while true; do
    clear
    header "TELESAFE LOGS MENU"
    echo "1) View last 50 log lines"
    echo "2) Follow logs (live tail, press Ctrl+C to exit)"
    echo "3) Search logs (keyword)"
    echo "4) Back to main menu"
    echo -n "Choice: "
    read c
    case "$c" in
      1) docker logs --tail 50 "$CONTAINER_NAME"; read -p "Press enter..." ;;
      2) docker logs -f "$CONTAINER_NAME";;
      3) read -p "Keyword: " kw; docker logs "$CONTAINER_NAME" | grep --color "$kw"; read -p "Press enter..." ;;
      4) break;;
      *) ;;
    esac
  done
}

function control_menu() {
  while true; do
    clear
    header "TELESAFE CONTROL MENU"
    echo "1) Start"
    echo "2) Stop"
    echo "3) Pause"
    echo "4) Unpause"
    echo "5) Remove"
    echo "6) Back"
    echo -n "Choice: "
    read c
    case "$c" in
      1) docker start "$CONTAINER_NAME"; sleep 1;;
      2) docker stop "$CONTAINER_NAME"; sleep 1;;
      3) docker pause "$CONTAINER_NAME"; sleep 1;;
      4) docker unpause "$CONTAINER_NAME"; sleep 1;;
      5) docker rm -f "$CONTAINER_NAME"; sleep 1;;
      6) break;;
      *) ;;
    esac
  done
}

function main_menu() {
  while true; do
    clear
    header "TELESAFE TERMINAL DASHBOARD"
    if ! command -v docker &>/dev/null; then
      error "Docker is not available in your shell. Please log out/in and retry."
      exit 1
    fi
    docker ps -a --filter name=$CONTAINER_NAME
    echo
    echo "Available actions:"
    echo "  1) Show live resource stats"
    echo "  2) Logs menu"
    echo "  3) Control menu (start/stop/pause/etc)"
    echo "  4) Refresh OpenAI-only firewall"
    echo "  5) Rebuild/redeploy container"
    echo "  6) Show container .env secrets path"
    echo "  7) Quit"
    echo -n "Choice: "
    read c
    case "$c" in
      1) show_stats;;
      2) show_logs;;
      3) control_menu;;
      4) restrict_to_openai; read -p "Firewall refreshed. Press enter...";;
      5) prompt_and_save_api_key; build_app; run_container; restrict_to_openai; read -p "Rebuilt and redeployed. Press enter...";;
      6) echo -e "\nThe secure .env file (API key) is at: $ENV_PATH\nPermissions: $(stat -c %A $ENV_PATH)\n"; read -p "Press enter...";;
      7) header "Bye! You can always re-run this script for the dashboard." ; exit 0;;
      *) ;;
    esac
  done
}

if [ "${1:-}" = "install" ]; then
  ensure_docker_installed
  configure_docker_user
  prep_network
  prompt_and_save_api_key
  build_app
  run_container
  restrict_to_openai
  header "Initial deploy complete. Log out/in if told, then re-run this script (no args) anytime for the dashboard."
else
  prep_network
  main_menu
fi

# ==============================================================================
#                              END OF SCRIPT
# ==============================================================================
