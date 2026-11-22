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

### Install picotron-daemon
# picopod is not in the Fedora repos — install via pip system-wide.
# Copy to /tmp first: pip writes egg-info back to the source dir,
# which fails on the read-only /ctx bind mount.
cp -r /ctx/daemon /tmp/daemon
pip install --prefix=/usr /tmp/daemon/
rm -rf /tmp/daemon

### Make scripts executable
chmod 755 \
    /usr/bin/picotron-import \
    /usr/bin/picotron-session

### Enable services
systemctl enable lightdm.service
# Start picotron-daemon for all users on login
systemctl --global enable picotron-daemon.service

# Disable other display managers if present
systemctl disable gdm.service 2>/dev/null || true
systemctl disable sddm.service 2>/dev/null || true
systemctl disable greetd.service 2>/dev/null || true
