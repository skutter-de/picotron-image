#!/bin/bash
set -ouex pipefail

# System-Dateien einspielen
cp -avf /ctx/system_files/. /

### Pakete installieren
dnf5 install -y \
    cage \
    lightdm \
    lightdm-gtk-greeter \
    pipewire \
    pipewire-pulseaudio \
    wireplumber \
    python3-pip \
    python3-flask

### picotron-daemon installieren
# picopod ist nicht im Fedora-Repo — via pip system-wide
pip install --prefix=/usr /ctx/daemon/

### Skripte ausführbar machen
chmod 755 \
    /usr/bin/picotron-import \
    /usr/bin/picotron-session

### Services aktivieren
systemctl enable lightdm.service
systemctl --global enable picotron-daemon.service

# GDM/SDDM/greetd deaktivieren falls vorhanden
systemctl disable gdm.service 2>/dev/null || true
systemctl disable sddm.service 2>/dev/null || true
systemctl disable greetd.service 2>/dev/null || true
