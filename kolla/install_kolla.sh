#!/bin/bash
set -e  # Exit immediately on error
set -o pipefail

##############################################
# Helper Functions
##############################################

error_exit() {
    echo "❌ ERROR: $1"
    exit 1
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || error_exit "Required command '$1' not found!"
}


KEY_PATH="$HOME/.ssh/id_ed25519"

echo "🔐 Generating SSH key..."
if [[ -f "$KEY_PATH" ]]; then
    echo "✔ SSH key already exists: $KEY_PATH"
else
    ssh-keygen -t ed25519 -C "vellingiribks@gmail.com" -f "$KEY_PATH" -N ""
fi

echo "🔧 Starting ssh-agent..."
eval "$(ssh-agent -s)"
ssh-add "$KEY_PATH"

echo "📋 Your public key (copy to GitHub → Settings → SSH Keys):"
echo "--------------------------------------------------------------"
cat "${KEY_PATH}.pub"
echo "--------------------------------------------------------------"

echo "👉 Test with: ssh -T git@github.com"

##############################################
# Pre-checks
##############################################

echo "🔍 Validating environment..."

REQUIRED_CMDS=("git" "python3" "pip" "sudo" "apt" "gcc")
for cmd in "${REQUIRED_CMDS[@]}"; do
    check_command "$cmd"
done

if [[ "$EUID" == 0 ]]; then
    error_exit "Do NOT run this script as root. Run as a normal user with sudo access."
fi

##############################################
# Git Configuration
##############################################

echo "🔧 Configuring git..."
git config --global user.email "vellingiribks@gmail.com"
git config --global user.name "Vellingiri Subramaniam"

##############################################
# Sudoers Modification Warning
##############################################


##############################################
# Update sudoers safely
##############################################

echo "🔧 Checking sudoers for passwordless sudo..."

# Pattern we want to add
SUDO_RULE="ubuntu ALL=(ALL:ALL) NOPASSWD:ALL"

# Check if rule already exists
if sudo grep -qF "$SUDO_RULE" /etc/sudoers; then
    echo "✔ sudoers entry already present."
else
    echo "⚠️  Adding passwordless sudo entry for ubuntu user..."
    echo "$SUDO_RULE" | sudo EDITOR="tee -a" visudo >/dev/null \
        || error_exit "Failed to update /etc/sudoers"
    echo "✔ sudoers updated successfully."
fi

##############################################
# System Updates & Dependency Installation
##############################################

echo "📦 Updating system packages..."
sudo apt update || error_exit "apt update failed"
sudo apt upgrade -y || error_exit "apt upgrade failed"

echo "📦 Installing dependencies..."
sudo apt install -y git python3-dev libffi-dev gcc libssl-dev \
                    libdbus-glib-1-dev python3-venv || error_exit "Dependency installation failed"

##############################################
# Python Virtual Environment
##############################################

echo "🐍 Creating Python venv..."

if [[ ! -d "kolla" ]]; then
    python3 -m venv kolla || error_exit "Failed to create venv"
fi

source kolla/bin/activate || error_exit "Failed to activate venv"

pip install -U pip
pip install docker pkgconfig dbus-python

##############################################
# Install Kolla-Ansible
##############################################

echo "📥 Installing Kolla-Ansible (master)..."
pip install git+https://opendev.org/openstack/kolla-ansible@master || error_exit "Kolla-Ansible install failed"

##############################################
# Kolla Configuration Files
##############################################

echo "📁 Preparing /etc/kolla..."

sudo mkdir -p /etc/kolla
sudo chown "$USER:$USER" /etc/kolla/

cp -r kolla/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp -v /tmp/globals.yml /etc/kolla

##############################################
# Inventory Setup
##############################################

echo "📁 Setting up inventory..."
cp kolla/share/kolla-ansible/ansible/inventory/all-in-one ./all-in-one

##############################################
# Install Ansible Dependencies
##############################################

echo "🧩 Installing Ansible dependencies..."
kolla-ansible install-deps || error_exit "install-deps failed"

##############################################
# Generate Passwords
##############################################

echo "🔑 Generating passwords..."
kolla-genpwd || error_exit "Password generation failed"

##############################################
# Validate globals.yml Exists
##############################################

echo "🔍 Checking globals.yml..."
if [[ ! -f /etc/kolla/globals.yml ]]; then
    error_exit "/etc/kolla/globals.yml missing!"
fi

echo "📄 Using globals.yml:"
grep -v ^# /etc/kolla/globals.yml | grep -v ^$

##############################################
# Deploy Sequence
##############################################

echo "🚀 Running Kolla-Ansible deployment..."

kolla-ansible bootstrap-servers -i all-in-one || error_exit "bootstrap-servers failed"
kolla-ansible prechecks -i all-in-one || error_exit "prechecks failed"
kolla-ansible deploy -i all-in-one || error_exit "deploy failed"

##############################################
# OpenStack Client
##############################################

echo "📦 Installing OpenStack CLI..."
pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/master || error_exit "openstackclient install failed"

##############################################
# Post-deploy Setup
##############################################

echo "🛠️ Post deployment setup..."
kolla-ansible post-deploy -i all-in-one || error_exit "post-deploy failed"

mkdir -p ~/.config/openstack
cp /etc/kolla/clouds.yaml ~/.config/openstack/

##############################################
# Update bashrc
##############################################

echo "⚙️ Updating .bashrc with OS_CLOUD and venv..."
if ! grep -q "OS_CLOUD=" ~/.bashrc; then
    echo 'export OS_CLOUD=kolla-admin' >> ~/.bashrc
fi

if ! grep -q "source ~/kolla/bin/activate" ~/.bashrc; then
    echo 'source ~/kolla/bin/activate' >> ~/.bashrc
fi

##############################################
# Docker Permissions
##############################################

echo "🐳 Adding user to docker group..."
sudo usermod -aG docker "$USER"

##############################################
# Create Example Flavors
##############################################

echo "📦 Creating example flavors..."

# Always check before creating
if ! openstack flavor show m1.small >/dev/null 2>&1; then
    openstack flavor create m1.small --vcpus 2 --ram 2048 --disk 30
fi

if ! openstack flavor show m1.medium >/dev/null 2>&1; then
    openstack flavor create m1.medium --vcpus 4 --ram 4096 --disk 40
fi

##############################################
# Final Summary
##############################################

echo ""
echo "🎉 Kolla-Ansible deployment completed successfully!"
echo ""
echo "📊 Useful verification commands:"
echo "   openstack service list"
echo "   openstack compute service list"
echo "   openstack network agent list"
echo "   docker ps"
echo "   grep keystone_admin_password /etc/kolla/passwords.yml"
echo ""
echo "✅ You may need to logout/login for docker group changes."
