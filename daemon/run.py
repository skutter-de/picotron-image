import os
from flask import Flask

from routes.system.health import bp as system_health_bp
from routes.system.info import bp as system_info_bp

app = Flask(__name__)
app.register_blueprint(system_health_bp)
app.register_blueprint(system_info_bp)


def main():
    port = int(os.environ.get("PICOTRON_DAEMON_PORT", 2424))
    app.run(host="127.0.0.1", port=port)


if __name__ == "__main__":
    main()
