{
  description = "Boot a real, independent Ubuntu 24.04 LTS VM (QEMU: own kernel, 8 cores, 8 GiB RAM, NAT internet)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };

      ubuntu-vm = pkgs.writeShellApplication {
        name = "ubuntu-vm";
        runtimeInputs = with pkgs; [ qemu cloud-utils curl coreutils ];
        text = ''
          url="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"

          # Base image is cached once in a stable, reboot-persistent dir (never in /tmp),
          # so it is downloaded a single time regardless of where you run this from.
          cache="''${XDG_CACHE_HOME:-$HOME/.cache}/ubuntu-vm"
          base="$cache/ubuntu-24.04-cloudimg-amd64.img"
          mkdir -p "$cache"
          [ -f "$base" ] || curl -L -o "$base" "$url"

          # The writable overlay + cloud-init seed are per-VM state, kept in the current dir.
          # Delete ubuntu-vm.qcow2 to reset the VM to a pristine image.
          disk="ubuntu-vm.qcow2"
          [ -f "$disk" ] || qemu-img create -f qcow2 -F qcow2 -b "$base" "$disk" 20G

          # cloud-init seed: login user "ubuntu" with password "ubuntu".
          printf '%s\n' \
            '#cloud-config' \
            'password: ubuntu' \
            'chpasswd: { expire: false }' \
            'ssh_pwauth: true' > user-data
          echo "instance-id: iid-local01" > meta-data
          cloud-localds seed.img user-data meta-data

          # Use KVM acceleration when /dev/kvm is available; otherwise fall back to slow emulation.
          accel=()
          if [ -w /dev/kvm ]; then accel=(-enable-kvm -cpu host); fi

          # 8 GiB RAM, 8 vCPUs, user-mode (NAT) networking for outbound internet without
          # root; hostfwd exposes the guest's sshd on host port 2222.
          echo "SSH into the VM once booted:  ssh -p 2222 ubuntu@localhost   (password: ubuntu)" >&2
          echo "Serial console is here; quit QEMU with Ctrl-a x." >&2
          exec qemu-system-x86_64 \
            "''${accel[@]}" \
            -m 8G -smp 8 \
            -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
            -drive file="$disk",if=virtio \
            -drive file=seed.img,if=virtio,format=raw \
            -nographic
        '';
      };
    in {
      apps.default = { type = "app"; program = pkgs.lib.getExe ubuntu-vm; };
      packages.default = ubuntu-vm;
      devShells.default = pkgs.mkShell { packages = [ pkgs.qemu pkgs.cloud-utils ]; };
    });
}
