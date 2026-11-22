import os
import subprocess
import threading
import time
from flask import Flask, request, jsonify

app = Flask(__name__)

DONE_MARKER = "/var/lib/picotron/initial-setup-done"
PICOTRON_BIN = "/var/picotron/picotron"


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
            check=True, capture_output=True, text=True
        )
        proc = subprocess.run(
            ["chpasswd"],
            input=f"{username}:{password}\n",
            check=True, capture_output=True, text=True
        )
        subprocess.run(
            ["usermod", "-aG", "audio,video,input", username],
            capture_output=True
        )
    except subprocess.CalledProcessError as e:
        return jsonify({"ok": False, "error": e.stderr.strip() or str(e)}), 500

    return jsonify({"ok": True})


@app.post("/setup/finish")
def finish():
    os.makedirs(os.path.dirname(DONE_MARKER), exist_ok=True)
    with open(DONE_MARKER, "w") as f:
        f.write("done\n")

    def _start_lightdm():
        time.sleep(2)
        subprocess.run(["systemctl", "start", "display-manager.service"])

    threading.Thread(target=_start_lightdm, daemon=True).start()
    return jsonify({"ok": True})


def main():
    port = int(os.environ.get("PICOTRON_SETUP_PORT", 2425))
    app.run(host="127.0.0.1", port=port)


if __name__ == "__main__":
    main()
