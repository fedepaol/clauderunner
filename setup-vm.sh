#!/bin/bash
set -euo pipefail

VM_NAME="${1:-devbox}"
VM_IP="${2:-192.168.122.50}"
VM_USER="$(id -un)"
VCPUS=4
RAM_MB=8192
DISK_GB=60
FEDORA_VERSION=42
IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-${FEDORA_VERSION}-1.1.x86_64.qcow2"
IMAGE_DIR="/var/lib/libvirt/images"
IMAGE_FILE="${IMAGE_DIR}/${VM_NAME}.qcow2"
CLOUD_INIT_DIR="$(mktemp -d)"

SSH_PUBKEYS=()
for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
  [ -f "$keyfile" ] && SSH_PUBKEYS+=("$(cat "$keyfile")")
done
if [ ${#SSH_PUBKEYS[@]} -eq 0 ]; then
  echo "ERROR: No SSH public key found in ~/.ssh/"
  exit 1
fi

# Check required tools
for cmd in virsh virt-install qemu-img genisoimage curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed."
    case "$cmd" in
      virsh|virt-install) echo "  sudo dnf install libvirt virt-install" ;;
      qemu-img)           echo "  sudo dnf install qemu-img" ;;
      genisoimage)        echo "  sudo dnf install genisoimage" ;;
    esac
    exit 1
  fi
done

# Check if VM already exists
if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "ERROR: VM '${VM_NAME}' already exists. Run ./teardown-vm.sh first."
  exit 1
fi

# --- Download base image ---
DOWNLOAD_PATH="${IMAGE_DIR}/Fedora-Cloud-Base-Generic-${FEDORA_VERSION}.qcow2"
if [ ! -f "$DOWNLOAD_PATH" ] || [ "$(sudo stat -c%s "$DOWNLOAD_PATH" 2>/dev/null)" -lt 1000000 ]; then
  echo "==> Downloading Fedora ${FEDORA_VERSION} cloud image..."
  sudo rm -f "$DOWNLOAD_PATH"
  sudo curl -L --fail -o "$DOWNLOAD_PATH" "$IMAGE_URL"
  FILE_SIZE=$(sudo stat -c%s "$DOWNLOAD_PATH")
  if [ "$FILE_SIZE" -lt 1000000 ]; then
    echo "ERROR: Downloaded file is too small (${FILE_SIZE} bytes). URL may be wrong."
    sudo rm -f "$DOWNLOAD_PATH"
    exit 1
  fi
else
  echo "==> Using cached Fedora image"
fi

echo "==> Creating VM disk (${DISK_GB}G)..."
sudo cp "$DOWNLOAD_PATH" "$IMAGE_FILE"
sudo qemu-img resize -f qcow2 "$IMAGE_FILE" ${DISK_GB}G

# --- Cloud-init user-data ---
cat > "${CLOUD_INIT_DIR}/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: clauderunner
EOF

cat > "${CLOUD_INIT_DIR}/user-data" <<EOF
#cloud-config
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: wheel
    ssh_authorized_keys:
$(printf '      - %s\n' "${SSH_PUBKEYS[@]}")

chpasswd:
  list: |
    root:devbox
  expire: false

runcmd:
  - [mkdir, -p, /var/tmp/provision]
  - [mount, /dev/disk/by-label/PROVISION, /mnt]
  - [bash, -c, "cp -a /mnt/* /var/tmp/provision/"]
  - [umount, /mnt]
  - [bash, /var/tmp/provision/bootstrap.sh]
EOF

# --- Bootstrap script (runs as root inside the VM) ---
mkdir -p "${CLOUD_INIT_DIR}/provision"

cat > "${CLOUD_INIT_DIR}/provision/bootstrap.sh" <<'BOOTSTRAP'
#!/bin/bash
set -euo pipefail
LOG=/var/log/provision.log
exec > >(tee -a "$LOG") 2>&1

retry() {
  local max_attempts=$1; shift
  local attempt=1
  until "$@"; do
    if [ $attempt -ge $max_attempts ]; then
      echo "FAILED after $max_attempts attempts: $*"
      return 1
    fi
    echo "Attempt $attempt failed, retrying in 10s..."
    sleep 10
    attempt=$((attempt + 1))
  done
}

echo "==> Waiting for network..."
for i in $(seq 1 30); do
  if curl -sf --connect-timeout 3 https://fedoraproject.org/ >/dev/null 2>&1; then
    break
  fi
  echo "  waiting... ($i)"
  sleep 2
done

echo "==> Installing packages..."
retry 5 dnf install -y --skip-unavailable \
  zsh neovim tmux git gcc make wget unzip \
  nodejs npm ripgrep fd-find jq pipx

echo "==> Installing lazygit from COPR..."
dnf copr enable -y atim/lazygit
retry 3 dnf install -y lazygit || echo "WARNING: lazygit install failed, skipping"

echo "==> Switching shell to zsh..."
chsh -s /bin/zsh fpaoline

echo "==> Installing GitHub CLI..."
retry 3 dnf install -y 'dnf-command(config-manager)'
dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo || true
retry 3 dnf install -y gh

echo "==> Installing Google Cloud CLI..."
tee /etc/yum.repos.d/google-cloud-sdk.repo <<'GCLOUD_REPO'
[google-cloud-cli]
name=Google Cloud CLI
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
GCLOUD_REPO
retry 3 dnf install -y google-cloud-cli

echo "==> Installing Docker CE..."
dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo || true
retry 3 dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker fpaoline

echo "==> Installing Go..."
retry 3 bash -c 'curl -sfL https://go.dev/dl/go1.24.10.linux-amd64.tar.gz | tar -C /usr/local -xzf -'

echo "==> Running user setup..."
su - fpaoline -c 'bash /var/tmp/provision/user-setup.sh'

echo "==> Provision complete!"
BOOTSTRAP
sed -i "s/fpaoline/${VM_USER}/g" "${CLOUD_INIT_DIR}/provision/bootstrap.sh"

# --- User setup script (runs as ${VM_USER}) ---
cat > "${CLOUD_INIT_DIR}/provision/user-setup.sh" <<'SETUP'
#!/bin/bash
set -euo pipefail
export HOME=/home/fpaoline
cd ~

retry() {
  local max_attempts=$1; shift
  local attempt=1
  until "$@"; do
    if [ $attempt -ge $max_attempts ]; then
      echo "FAILED after $max_attempts attempts: $*"
      return 1
    fi
    echo "Attempt $attempt failed, retrying in 10s..."
    sleep 10
    attempt=$((attempt + 1))
  done
}

# Oh-My-Zsh
export RUNZSH=no CHSH=no
retry 3 bash -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'

# Copy configs from provision dir
cp /var/tmp/provision/zshrc ~/.zshrc
cp /var/tmp/provision/gitconfig ~/.gitconfig
cp /var/tmp/provision/gitmessage ~/.gitmessage

# Override prompt to show clauderunner:
echo 'PROMPT="clauderunner: ${PROMPT}"' >> ~/.zshrc

# Add claudio alias
echo "alias claudio='claude --dangerously-skip-permissions'" >> ~/.zshrc

# Claude Code settings - allow all tools for autonomous operation
mkdir -p ~/.claude
cat > ~/.claude/settings.json <<'CLAUDE_SETTINGS'
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Edit(*)",
      "Write(*)",
      "Read(*)",
      "WebFetch(*)",
      "WebSearch(*)",
      "Glob(*)",
      "Grep(*)",
      "NotebookEdit(*)"
    ]
  }
}
CLAUDE_SETTINGS

# gcloud credentials
if [ -d /var/tmp/provision/gcloud ]; then
  mkdir -p ~/.config/gcloud
  cp -a /var/tmp/provision/gcloud/* ~/.config/gcloud/
fi

# gh CLI credentials
if [ -d /var/tmp/provision/gh ]; then
  mkdir -p ~/.config/gh
  cp -a /var/tmp/provision/gh/* ~/.config/gh/
fi

# Fix gitconfig excludesfile path
sed -i "s|/home/fedepaol|/home/fpaoline|" ~/.gitconfig

# Neovim
mkdir -p ~/.config/nvim/lua/config ~/.config/nvim/lua/plugins
cp /var/tmp/provision/nvim/init.lua ~/.config/nvim/init.lua
cp /var/tmp/provision/nvim/lazy-lock.json ~/.config/nvim/lazy-lock.json
cp /var/tmp/provision/nvim/lua/mappings.lua ~/.config/nvim/lua/mappings.lua
cp /var/tmp/provision/nvim/lua/options.lua ~/.config/nvim/lua/options.lua
cp /var/tmp/provision/nvim/lua/autocommands.lua ~/.config/nvim/lua/autocommands.lua
cp /var/tmp/provision/nvim/lua/commands.lua ~/.config/nvim/lua/commands.lua
cp /var/tmp/provision/nvim/lua/config/lazy.lua ~/.config/nvim/lua/config/lazy.lua
cp /var/tmp/provision/nvim/lua/plugins/all.lua ~/.config/nvim/lua/plugins/all.lua
cp /var/tmp/provision/nvim/lua/plugins/gitsigns.lua ~/.config/nvim/lua/plugins/gitsigns.lua
cp /var/tmp/provision/nvim/lua/plugins/lazygit.lua ~/.config/nvim/lua/plugins/lazygit.lua

# Install nvim plugins
nvim --headless "+Lazy! sync" +qa 2>/dev/null || true

# Go tools
export PATH=$PATH:/usr/local/go/bin:~/go/bin
retry 3 go install golang.org/x/tools/gopls@latest
retry 3 go install golang.org/x/tools/cmd/goimports@latest
pipx install specify-cli
npm install -g diffity

# Claude Code (native binary)
retry 3 bash -c 'curl -fsSL https://claude.ai/install.sh | sh'

echo "==> User setup complete!"
SETUP
sed -i "s/fpaoline/${VM_USER}/g" "${CLOUD_INIT_DIR}/provision/user-setup.sh"

# --- Copy actual config files into provision dir ---
cp ~/.zshrc "${CLOUD_INIT_DIR}/provision/zshrc"
cp ~/.gitconfig "${CLOUD_INIT_DIR}/provision/gitconfig"
cp ~/.gitmessage "${CLOUD_INIT_DIR}/provision/gitmessage"

# gcloud credentials (if authenticated on host)
if [ -d ~/.config/gcloud ]; then
  echo "==> Including gcloud credentials"
  cp -a ~/.config/gcloud "${CLOUD_INIT_DIR}/provision/gcloud"
fi

# gh CLI credentials (if authenticated on host)
if [ -d ~/.config/gh ]; then
  echo "==> Including gh credentials"
  cp -a ~/.config/gh "${CLOUD_INIT_DIR}/provision/gh"
fi

mkdir -p "${CLOUD_INIT_DIR}/provision/nvim/lua/config"
mkdir -p "${CLOUD_INIT_DIR}/provision/nvim/lua/plugins"
cp ~/.config/nvim/init.lua "${CLOUD_INIT_DIR}/provision/nvim/init.lua"
cp ~/.config/nvim/lazy-lock.json "${CLOUD_INIT_DIR}/provision/nvim/lazy-lock.json"
cp ~/.config/nvim/lua/mappings.lua "${CLOUD_INIT_DIR}/provision/nvim/lua/mappings.lua"
cp ~/.config/nvim/lua/options.lua "${CLOUD_INIT_DIR}/provision/nvim/lua/options.lua"
cp ~/.config/nvim/lua/autocommands.lua "${CLOUD_INIT_DIR}/provision/nvim/lua/autocommands.lua"
cp ~/.config/nvim/lua/commands.lua "${CLOUD_INIT_DIR}/provision/nvim/lua/commands.lua"
cp ~/.config/nvim/lua/config/lazy.lua "${CLOUD_INIT_DIR}/provision/nvim/lua/config/lazy.lua"
cp ~/.config/nvim/lua/plugins/all.lua "${CLOUD_INIT_DIR}/provision/nvim/lua/plugins/all.lua"
cp ~/.config/nvim/lua/plugins/gitsigns.lua "${CLOUD_INIT_DIR}/provision/nvim/lua/plugins/gitsigns.lua"
cp ~/.config/nvim/lua/plugins/lazygit.lua "${CLOUD_INIT_DIR}/provision/nvim/lua/plugins/lazygit.lua"

# --- Create cloud-init ISO ---
echo "==> Creating cloud-init ISO..."
CLOUD_INIT_ISO="${IMAGE_DIR}/${VM_NAME}-cloud-init.iso"
sudo genisoimage -output "$CLOUD_INIT_ISO" -volid cidata -joliet -rock \
  "${CLOUD_INIT_DIR}/user-data" "${CLOUD_INIT_DIR}/meta-data"

# --- Create provision ISO (config files delivered via second disk) ---
echo "==> Creating provision ISO..."
PROVISION_ISO="${IMAGE_DIR}/${VM_NAME}-provision.iso"
sudo genisoimage -output "$PROVISION_ISO" -volid PROVISION -joliet -rock \
  -graft-points \
  bootstrap.sh="${CLOUD_INIT_DIR}/provision/bootstrap.sh" \
  user-setup.sh="${CLOUD_INIT_DIR}/provision/user-setup.sh" \
  zshrc="${CLOUD_INIT_DIR}/provision/zshrc" \
  gitconfig="${CLOUD_INIT_DIR}/provision/gitconfig" \
  gitmessage="${CLOUD_INIT_DIR}/provision/gitmessage" \
  nvim/="${CLOUD_INIT_DIR}/provision/nvim/" \
  $([ -d "${CLOUD_INIT_DIR}/provision/gcloud" ] && echo "gcloud/=${CLOUD_INIT_DIR}/provision/gcloud/") \
  $([ -d "${CLOUD_INIT_DIR}/provision/gh" ] && echo "gh/=${CLOUD_INIT_DIR}/provision/gh/")

# --- Reserve a static DHCP lease on the libvirt network ---
VM_MAC="52:54:00:cc:cc:01"
echo "==> Adding DHCP reservation ${VM_IP} -> ${VM_MAC}..."
sudo virsh net-update default add ip-dhcp-host \
  "<host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>" \
  --live --config 2>/dev/null || echo "  (reservation may already exist)"

# --- Create VM ---
echo "==> Creating VM '${VM_NAME}'..."
sudo virt-install \
  --name "${VM_NAME}" \
  --memory ${RAM_MB} \
  --vcpus ${VCPUS} \
  --disk path="${IMAGE_FILE}",format=qcow2 \
  --disk path="${CLOUD_INIT_ISO}",device=cdrom \
  --disk path="${PROVISION_ISO}",device=cdrom \
  --os-variant fedora${FEDORA_VERSION} \
  --network network=default,mac="${VM_MAC}" \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole \
  --import

rm -rf "${CLOUD_INIT_DIR}"

# --- Wait for VM to be reachable via SSH ---
echo ""
echo "==> Waiting for VM to be reachable at ${VM_IP}..."
for i in $(seq 1 60); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 -o BatchMode=yes \
    ${VM_USER}@${VM_IP} true 2>/dev/null; then
    break
  fi
  printf "."
  sleep 3
done
echo ""

# --- Wait for cloud-init to finish ---
echo "==> Waiting for cloud-init to finish provisioning..."
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_IP} \
  'sudo cloud-init status --wait' 2>/dev/null || true

# --- Check result ---
RESULT=$(ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_IP} 'sudo cloud-init status' 2>/dev/null)
if echo "$RESULT" | grep -q "done"; then
  echo "==> Provisioning complete!"
else
  echo "==> Provisioning finished with status: ${RESULT}"
  echo "    Check: ssh ${VM_USER}@${VM_IP} 'sudo cat /var/log/provision.log'"
fi
echo ""
echo "Connect:     ssh ${VM_USER}@${VM_IP}"
echo "Console:     sudo virsh console ${VM_NAME}"
