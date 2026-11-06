# clauderunner

Provisions a disposable Fedora VM (via libvirt/KVM) pre-configured for autonomous CLI agent usage.

The VM comes with: Go, Docker, GitHub CLI, GitHub Copilot CLI, Google Cloud CLI, Neovim, zsh, [diffity](https://github.com/kamranahmedse/diffity), Claude Code with `--dangerously-skip-permissions` aliased as `claudio`, and Codex CLI. Caveman installs for Claude, Codex, and Copilot and defaults to `ultra` mode.

## Prerequisites

- A Linux host with libvirt, QEMU/KVM, and `virt-install`
- SSH public key in `~/.ssh/`
- (Optional) `gh` and `gcloud` credentials in `~/.config/` — they'll be copied into the VM
- (Optional) Host `~/.env` and Codex authentication, settings, and profiles (`~/.codex/auth.json`, `config.toml`, and `*.config.toml`) are copied; host session history stays on host. Codex aliases come from the copied `~/.zshrc`.

## Usage

### Create a VM

```bash
./setup-vm.sh [vm-name] [vm-ip]
```

Defaults to `devbox` and `192.168.122.50`. Example:

```bash
./setup-vm.sh myvm 192.168.122.100
```

### Connect

```bash
ssh <your-user>@<vm-ip>
```

### Tear down

```bash
./teardown-vm.sh [vm-name] [vm-ip]
```

## Accessing web tools (e.g. diffity) from a remote laptop

If the VM runs on a server and you're working from a laptop, the network topology is:

```
laptop --> server --> VM --> diffity (:5391)
```

Use SSH port forwarding through the server (no need to SSH into the VM):

```bash
ssh -L 5391:<vm-ip>:5391 <your-user>@<server-ip>
```

Then open `http://localhost:5391` on your laptop.

This works because the server (hypervisor) has direct network access to the VM on the libvirt bridge.
