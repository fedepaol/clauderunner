# clauderunner

Provisions a disposable Fedora VM (via libvirt/KVM) pre-configured for autonomous Claude Code usage.

The VM comes with: Go, Docker, GitHub CLI, Google Cloud CLI, Neovim, zsh, [diffity](https://github.com/kamranahmedse/diffity), and Claude Code with `--dangerously-skip-permissions` aliased as `claudio`.

## Prerequisites

- A Linux host with libvirt, QEMU/KVM, and `virt-install`
- SSH public key in `~/.ssh/`
- (Optional) `gh` and `gcloud` credentials in `~/.config/` — they'll be copied into the VM

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
