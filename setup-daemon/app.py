import os
import signal
import subprocess
import threading
import time

from flask import Flask, jsonify, request

app = Flask(__name__)

DONE_MARKER = "/var/lib/picotron/initial-setup-done"
PICOTRON_BIN = "/var/picotron/picotron"
STATE_FILE = "/tmp/picotron-setup-state"
KEYMAP_FILE = "/tmp/picotron-setup-keymap"
LOCALE_FILE = "/tmp/picotron-setup-locale"

# In-memory state (also written to STATE_FILE for cage-restart persistence)
_state = {"screen": "language"}


def _load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            _state["screen"] = f.read().strip() or "language"


def _save_state(screen):
    _state["screen"] = screen
    with open(STATE_FILE, "w") as f:
        f.write(screen)


def _find_cage_pid():
    try:
        out = subprocess.check_output(["pgrep", "-x", "cage"], text=True)
        return int(out.strip().split()[0])
    except Exception:
        return None


@app.get("/setup/state")
def get_state():
    _load_state()
    return jsonify({
        "screen": _state["screen"],
        "keymap": open(KEYMAP_FILE).read().strip() if os.path.exists(KEYMAP_FILE) else "us",
        "locale": open(LOCALE_FILE).read().strip() if os.path.exists(LOCALE_FILE) else "en_US.UTF-8",
    })


@app.post("/setup/set_locale")
def set_locale():
    locale = request.form.get("locale", "en_US.UTF-8")
    with open(LOCALE_FILE, "w") as f:
        f.write(locale)
    _save_state("keymap")
    return jsonify({"ok": True})


@app.post("/setup/apply_keymap")
def apply_keymap():
    """Write keymap and restart cage so XKB_DEFAULT_LAYOUT takes effect."""
    keymap = request.form.get("keymap", "us")
    with open(KEYMAP_FILE, "w") as f:
        f.write(keymap)
    _save_state("create_user")

    def _kill_cage():
        time.sleep(0.3)
        pid = _find_cage_pid()
        if pid:
            os.kill(pid, signal.SIGTERM)

    threading.Thread(target=_kill_cage, daemon=True).start()
    return jsonify({"ok": True})


@app.get("/setup/picotron_status")
def picotron_status():
    return jsonify({"installed": os.path.isfile(PICOTRON_BIN)})


@app.post("/setup/create_user")
def create_user():
    username = request.form.get("username", "").strip()
    password = request.form.get("password", "")

    if not username:
        return jsonify({"ok": False, "error": "username required"}), 400
    if len(password) < 4:
        return jsonify({"ok": False, "error": "password too short"}), 400

    try:
        subprocess.run(
            ["useradd", "-m", "-s", "/bin/bash", username],
            check=True, capture_output=True, text=True,
        )
        subprocess.run(
            ["chpasswd"],
            input=f"{username}:{password}\n",
            check=True, capture_output=True, text=True,
        )
        subprocess.run(
            ["usermod", "-aG", "audio,video,input", username],
            capture_output=True,
        )
    except subprocess.CalledProcessError as e:
        return jsonify({"ok": False, "error": e.stderr.strip() or str(e)}), 500

    _save_state("done")
    return jsonify({"ok": True})


@app.post("/setup/finish")
def finish():
    # Apply locale and keymap system-wide
    locale = open(LOCALE_FILE).read().strip() if os.path.exists(LOCALE_FILE) else "en_US.UTF-8"
    keymap = open(KEYMAP_FILE).read().strip() if os.path.exists(KEYMAP_FILE) else "us"
    subprocess.run(["localectl", "set-locale", f"LANG={locale}"], capture_output=True)
    subprocess.run(["localectl", "set-keymap", keymap], capture_output=True)

    os.makedirs(os.path.dirname(DONE_MARKER), exist_ok=True)
    with open(DONE_MARKER, "w") as f:
        f.write("done\n")

    def _start_lightdm():
        time.sleep(2)
        subprocess.run(["systemctl", "start", "display-manager.service"])

    threading.Thread(target=_start_lightdm, daemon=True).start()
    return jsonify({"ok": True})


def main():
    _load_state()
    port = int(os.environ.get("PICOTRON_SETUP_PORT", 2425))
    app.run(host="127.0.0.1", port=port)


if __name__ == "__main__":
    main()
