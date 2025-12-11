#!/bin/bash
set -e
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN} KOLLA-ANSIBLE FULL CLEANUP SCRIPT                            ${NC}"
echo -e "${GREEN}=============================================================${NC}"

# Confirm
read -p "⚠️  This will remove ALL OpenStack containers, configs, volumes. Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && { echo "Aborted."; exit 1; }

#####################################
# Step 1 — Kolla-Ansible destroy
#####################################

echo -e "${GREEN}🧹 Running kolla-ansible destroy...${NC}"
if command -v kolla-ansible >/dev/null 2>&1; then
    kolla-ansible destroy -i $HOME/all-in-one --yes-i-really-really-mean-it || true
else
    echo "⚠️  kolla-ansible not installed — skipping destroy phase."
fi

#####################################
# Step 2 — Remove neutron namespaces
#####################################

echo -e "${GREEN}🧹 Removing leftover network namespaces...${NC}"
for ns in $(ip netns list | awk '{print $1}'); do
    echo " - Deleting namespace: $ns"
    ip netns delete "$ns" || true
done

#####################################
# Step 3 — Remove Docker containers/images/volumes
#####################################

echo -e "${GREEN}🐳 Cleaning Docker containers, images, volumes...${NC}"

if command -v docker >/dev/null 2>&1; then
    docker ps -aq | xargs -r docker rm -f || true
    docker images -aq | xargs -r docker rmi -f || true
    docker volume prune -f || true
else
    echo "⚠️  Docker not installed — skipping container cleanup."
fi

#####################################
# Step 4 — Remove OVS bridges (if present)
#####################################

if command -v ovs-vsctl >/dev/null 2>&1; then
    echo -e "${GREEN}🧹 Removing Open vSwitch bridges...${NC}"
    ovs-vsctl list-br | while read -r br; do
        echo " - Deleting OVS bridge: $br"
        ovs-vsctl del-br "$br" || true
    done
else
    echo "✔ OVS not installed — skipping."
fi

#####################################
# Step 5 — Remove Linux bridges
#####################################

echo -e "${GREEN}🧹 Removing Linux bridges br-ex / br-int...${NC}"

for br in br-ex br-int; do
    if ip link show "$br" >/dev/null 2>&1; then
        echo " - Deleting bridge: $br"
        ip link set "$br" down || true
        ip link delete "$br" type bridge || true
    fi
done

#####################################
# Step 6 — Remove Kolla directories
#####################################

echo -e "${GREEN}🗂 Removing Kolla directories...${NC}"

sudo rm -rf /etc/kolla || true
sudo rm -rf /var/lib/kolla || true
sudo rm -rf /var/log/kolla || true
sudo rm -rf /var/lib/docker/volumes/kolla* || true

#####################################
# Step 7 — Optional Docker purge
#####################################

read -p "❓ Do you want to completely remove Docker also? (yes/no): " purge_docker
if [[ "$purge_docker" == "yes" ]]; then
    echo -e "${GREEN}🔥 Purging Docker and containerd...${NC}"
    sudo apt purge -y docker-ce docker-ce-cli docker-compose-plugin containerd.io || true
    sudo rm -rf /var/lib/docker /var/lib/containerd
fi

#####################################
# Final summary
#####################################

echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN}✔ Kolla-Ansible cleanup complete!${NC}"
echo -e "${GREEN}=============================================================${NC}"

echo "🔍 Verification commands:"
echo " - docker ps"
echo " - ip netns list"
echo " - ovs-vsctl list-br"
echo " - ls /etc/kolla"
echo " - ls /var/lib/docker/volumes | grep kolla"

echo -e "${GREEN}System ready for fresh Kolla deployment.${NC}"
