#!/bin/bash
set -ouex pipefail

# Copy system files into the image
cp -avf /ctx/system_files/. /

### Install packages
dnf5 install -y \
    cage \
    lightdm \
    lightdm-gtk-greeter \
    pipewire \
    pipewire-pulseaudio \
    wireplumber \
    python3-pip \
    python3-flask

### Install picotron-daemon (control center, runs as user unit)
# picopod is not in the Fedora repos — install via pip system-wide.
# Copy to /tmp first: pip writes egg-info back to the source dir,
# which fails on the read-only /ctx bind mount.
cp -r /ctx/daemon /tmp/daemon
pip install --prefix=/usr /tmp/daemon/
rm -rf /tmp/daemon

### Install picotron-setup-daemon (first-boot wizard, runs as root)
cp -r /ctx/setup-daemon /tmp/setup-daemon
pip install --prefix=/usr /tmp/setup-daemon/
rm -rf /tmp/setup-daemon

### Install setup cart (used by picotron-initial-setup.service)
mkdir -p /usr/share/picotron/setup.p64
cp /ctx/setup-cart/main.lua /usr/share/picotron/setup.p64/main.lua

### Make scripts executable
chmod 755 \
    /usr/bin/picotron-import \
    /usr/bin/picotron-initial-setup \
    /usr/bin/picotron-session

### Enable services
systemctl enable lightdm.service
systemctl enable picotron-initial-setup.service
# Start picotron-daemon for all users on login
systemctl --global enable picotron-daemon.service

# Disable other display managers if present
systemctl disable gdm.service 2>/dev/null || true
systemctl disable sddm.service 2>/dev/null || true
systemctl disable greetd.service 2>/dev/null || true
