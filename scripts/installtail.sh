#!/bin/bash

# ANSI color codes
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Warn with a prompt if we're running as root
SUDO=sudo
if [ "$EUID" -eq 0 ]; then
    echo -e "${ORANGE}WARNING: You are running this script as root. It is recommended to run this script as a non-root user.${NC}"
    echo -e "${ORANGE}Do you want to continue? (y/n)${NC}"
    read choice

    if [ "$choice" != "y" ] && [ "$choice" != "Y" ]; then
        echo -e "${ORANGE}Aborting installation.${NC}"
        exit 1
    fi

    SUDO=
fi

# CD to project root if we're in the scripts dir
current_dir=$(pwd)
if [ "$(basename "$current_dir")" = "scripts" ]; then
    cd ..
fi

# Python version verification
if ! command -v python3 &>/dev/null; then
    echo -e "${ORANGE}Python 3 is not installed or not found. Please install at least Python 3.9 before you continue.${NC}"
    exit 1
fi

python_version=$(python3 --version) || exit 1
version_number=$(echo "$python_version" | awk '{print $2}')
IFS='.' read -r major minor patch <<< "$version_number"

if [[ "$major" -eq 3 && "$minor" -ge 9 ]]; then
    echo -e "${GREEN}Python 3.9 or later is installed (Current version: $version_number)${NC}"
else
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$VERSION_CODENAME" == "buster" ]]; then
            echo -e "${ORANGE}Python 3.9 or later is not installed (Current version: $version_number)${NC}"
            echo -e "${ORANGE}You are running an outdated version of Debian/Raspbian (Buster). Please upgrade to Bullseye.${NC}"
            exit 1
        fi
    fi
    echo -e "${ORANGE}Current version of Python ($version_number) is too old for Spoolman.${NC}"
    exit 1
fi

# Get OS package manager
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "$ID_LIKE" == *"debian"* || "$ID" == *"debian"* ]]; then
        pkg_manager="apt-get"
        update_cmd="$SUDO $pkg_manager update"
        install_cmd="$SUDO $pkg_manager install -y"
        echo -e "${GREEN}Detected Debian-based system. Using apt-get.${NC}"
    elif [[ "$ID_LIKE" == *"arch"* || "$ID" == *"arch"* ]]; then
        pkg_manager="pacman"
        update_cmd="$SUDO $pkg_manager -Sy"
        install_cmd="$SUDO $pkg_manager -S --noconfirm"
        echo -e "${GREEN}Detected Arch-based system. Using pacman.${NC}"
    else
        echo -e "${ORANGE}Unsupported OS. Aborting.${NC}"
        exit 1
    fi
fi

# Update package cache
echo -e "${GREEN}Updating $pkg_manager cache...${NC}"
$update_cmd || exit 1

# Check required packages
packages=""
if ! python3 -c 'import venv, ensurepip' &>/dev/null; then
    packages+=" python3-venv"
fi
if ! command -v pip3 &>/dev/null; then
    packages+=" python3-pip"
fi
if ! command -v pg_config &>/dev/null; then
    packages+=" libpq-dev"
fi
if ! command -v unzip &>/dev/null; then
    packages+=" unzip"
fi
if [[ -n "$packages" ]]; then
    $install_cmd $packages || exit 1
fi

# Upgrade pip
echo -e "${GREEN}Updating pip...${NC}"
upgrade_output=$(python3 -m pip install --user --upgrade pip 2>&1)
exit_code=$?
is_externally_managed_env=$(echo "$upgrade_output" | grep "externally-managed-environment")
if [[ $exit_code -ne 0 && -z "$is_externally_managed_env" ]]; then
    echo "$upgrade_output"
    exit 1
else
    echo -e "${GREEN}Pip upgraded or managed by system.${NC}"
fi

# Install Python packages
echo -e "${GREEN}Installing setuptools and wheel...${NC}"
if [[ $is_externally_managed_env ]]; then
    $install_cmd python3-setuptools python3-wheel || exit 1
else
    pip3 install --user setuptools wheel || exit 1
fi

# Add Python bin to PATH
user_python_bin_dir=$(python3 -m site --user-base)/bin
export PATH=$user_python_bin_dir:$PATH

# Spoolman setup
echo -e "${GREEN}Installing Spoolman backend...${NC}"
if [ ! -d ".venv" ]; then
    python3 -m venv .venv || exit 1
fi
source .venv/bin/activate || exit 1
pip3 install -r requirements.txt || exit 1

# Create .env if missing
if [ ! -f ".env" ]; then
    echo -e "${ORANGE}Creating .env file...${NC}"
    cp .env.example .env
fi

# Set permissions
echo -e "${GREEN}Making scripts executable...${NC}"
chmod +x scripts/*.sh

# systemd setup
systemd_option=$1
if [ "$systemd_option" == "-systemd=no" ]; then
   choice="n"
elif [ "$systemd_option" == "-systemd=yes" ]; then
   choice="y"
else
   echo -e "${CYAN}Install Spoolman as systemd service? (y/n)${NC}"
   read choice
fi

if [ "$choice" == "y" ] || [ "$choice" == "Y" ]; then
    systemd_user_dir="$HOME/.config/systemd/user"
    service_name="Spoolman"

    if [ -f "$systemd_user_dir/$service_name.service" ]; then
        echo -e "${ORANGE}Removing existing systemd service...${NC}"
        systemctl --user stop Spoolman
        systemctl --user disable Spoolman
        rm "$systemd_user_dir/$service_name.service"
        systemctl --user daemon-reload
    fi

    script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    spoolman_dir=$(dirname "$script_dir")

    if [ ! -f "$spoolman_dir/pyproject.toml" ]; then
        echo -e "${ORANGE}pyproject.toml not found in $spoolman_dir. Aborting.${NC}"
        exit 1
    fi

    service_unit="[Unit]
Description=Spoolman

[Service]
Type=simple
ExecStart=bash $spoolman_dir/scripts/start.sh
WorkingDirectory=$spoolman_dir
User=$USER
Restart=always

[Install]
WantedBy=default.target
"

    service_file="/etc/systemd/system/$service_name.service"
    echo "$service_unit" | $SUDO tee "$service_file" > /dev/null
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$service_name"
    $SUDO systemctl start "$service_name"

    set -o allexport
    source .env
    set +o allexport

    local_ip=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}Spoolman is now running at ${ORANGE}http://$local_ip:$SPOOLMAN_PORT${NC}"
else
    echo -e "${ORANGE}Skipping systemd installation.${NC}"
    echo -e "${ORANGE}Start manually with 'bash scripts/start.sh'${NC}"
fi

#
# Tailwind CSS Integration
#
echo -e "${GREEN}Checking for Tailwind CSS setup...${NC}"

if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    echo -e "${ORANGE}Node.js or npm not found. Installing...${NC}"
    if [[ "$pkg_manager" == "apt-get" ]]; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO bash - || exit 1
        $SUDO apt-get install -y nodejs || exit 1
    elif [[ "$pkg_manager" == "pacman" ]]; then
        $SUDO pacman -S --noconfirm nodejs npm || exit 1
    else
        echo -e "${ORANGE}Unsupported OS. Install Node.js manually.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}Node.js and npm are already installed.${NC}"
fi

echo -e "${GREEN}Installing Tailwind CSS and dependencies...${NC}"
npm install -D tailwindcss postcss autoprefixer || exit 1
npx tailwindcss init -p || exit 1

mkdir -p static/css
cat > static/css/input.css <<EOL
@tailwind base;
@tailwind components;
@tailwind utilities;
EOL

cat > tailwind.config.js <<EOL
module.exports = {
  content: [
    "./templates/**/*.html",
    "./static/js/**/*.js"
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}
EOL

npx tailwindcss -i ./static/css/input.css -o ./static/css/main.css --minify || exit 1
echo -e "${GREEN}✅ Tailwind CSS compiled to static/css/main.css${NC}"

echo -e "${GREEN}Spoolman has been installed successfully!${NC}"
echo -e "${GREEN}You can now start modernizing the UI using Tailwind classes.${NC}"
