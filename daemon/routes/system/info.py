from flask import Blueprint
from picopod import pod

bp = Blueprint("system_info", __name__)

@bp.get("/system/info")
def system_info():
    data = {
        "uptime": 12345,      # Platzhalter
        "version": "0.1.0",   # Platzhalter
    }
    return pod(data), 200, {"Content-Type": "application/x-picopod"}