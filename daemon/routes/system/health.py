from flask import Blueprint
from picopod import pod

bp = Blueprint("system_health", __name__)

@bp.get("/system/health")
def get_system_health():
    data = {
        "status": "ok"
    }
    return pod(data), 200, {"Content-Type": "application/x-picopod"}