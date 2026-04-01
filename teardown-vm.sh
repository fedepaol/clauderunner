#!/bin/bash
set -euo pipefail

VM_NAME="${1:-devbox}"
VM_IP="${2:-192.168.122.50}"
VM_MAC="52:54:00:cc:cc:01"
IMAGE_DIR="/var/lib/libvirt/images"

if ! sudo virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "ERROR: VM '${VM_NAME}' does not exist"
  exit 1
fi

echo "==> Destroying VM '${VM_NAME}'..."
sudo virsh destroy "$VM_NAME" 2>/dev/null || true
sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true

# Remove ISOs if left behind
for iso in "${VM_NAME}-cloud-init.iso" "${VM_NAME}-provision.iso"; do
  [ -f "${IMAGE_DIR}/${iso}" ] && sudo rm -f "${IMAGE_DIR}/${iso}"
done

# Remove DHCP reservation
sudo virsh net-update default delete ip-dhcp-host \
  "<host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>" \
  --live --config 2>/dev/null || true

echo "==> VM '${VM_NAME}' removed."
