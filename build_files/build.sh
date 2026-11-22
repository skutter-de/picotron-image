#!/bin/bash
set -ouex pipefail

# System-Dateien einspielen
cp -avf /ctx/system_files/. /

### Pakete installieren

dnf5 install -y \
    cage \
    greetd \
    pipewire \
    pipewire-pulseaudio \
    wireplumber \
    python3-gobject \
    python3-flask \
    python3-flask-login

### Skripte ausführbar machen
chmod 755 \
    /usr/bin/picotron-import \
    /usr/bin/picotron-wait-splash \
    /usr/bin/picotron-greeter

### Services aktivieren
# greetd als Display Manager
systemctl enable greetd.service

# Picotron-Import-Trigger braucht keinen eigenen Enable —
# der Service wird von udev on-demand gestartet.

### GDM/SDDM falls vorhanden deaktivieren (base-atomic hat keines, aber sicher ist sicher)
systemctl disable gdm.service 2>/dev/null || true
systemctl disable sddm.service 2>/dev/null || true

### greeter-User anlegen (via sysusers.d, wird bei erstem Boot ausgeführt)
# Die sysusers.d-Datei liegt bereits in system_files/usr/lib/sysusers.d/
