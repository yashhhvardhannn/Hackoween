
import os
import time

import requests

BASE_URL = os.getenv("ENGINE_URL", "http://localhost:8080")
_RETRY_DELAY_SECONDS = 0.25
MAX_MOVE = 3.0   # metres per move; long clear moves mean fewer stops (the guide ticks go to 3 m)


def _request(method, path, **kwargs):
    """Make one engine request, retrying a connection failure once."""
    try:
        return requests.request(method, BASE_URL + path, **kwargs)
    except requests.ConnectionError:
        time.sleep(_RETRY_DELAY_SECONDS)
        return requests.request(method, BASE_URL + path, **kwargs)

def get_state():
    response = _request("GET", "/state", timeout=10)
    response.raise_for_status()
    return response.json()

def get_image():
    response = _request("GET", "/look", timeout=10)
    response.raise_for_status()
    return response.content

def get_depth():
    response = _request("GET", "/depth", timeout=10)
    response.raise_for_status()
    return response.json()

def execute_action(name, args=None):
    args = args or {}

    if name == "give_up":
        return {"gave_up": True}

    endpoints = {
        "move": "/move",
        "turn": "/turn",
        "pickup": "/pickup",
        "drop": "/drop",
        "throw": "/throw",
    }

    if name not in endpoints:
        raise ValueError(f"Unknown action: {name}")

    payload = {}

    if name in ("move", "throw"):
        payload["distance"] = args["distance"]

    elif name == "turn":
        payload["degrees"] = args["degrees"]

    response = _request(
        "POST", endpoints[name], json=payload, timeout=60
    )
    response.raise_for_status()
    return response.json()


def start_run(command, run_id):
    response = _request(
        "POST",
        "/run/start",
        json={"command": command, "run_id": run_id},
        timeout=10,
    )
    response.raise_for_status()
    return response.json()


def reset_scene():
    """Put the robot and all objects back at their start positions (development runs)."""
    response = _request("POST", "/reset", json={}, timeout=10)
    response.raise_for_status()
    return response.json()


def end_run(outcome):
    response = _request(
        "POST", "/run/end", json={"outcome": outcome}, timeout=10
    )
    response.raise_for_status()
    return response.json()


def validate_action(name, args):
    """
    Validate robot actions before execution.
    Limits are provisional until Godot is calibrated.
    """

    if name == "move":
        distance = args.get("distance")

        if (
            isinstance(distance, bool)
            or not isinstance(distance, (int, float))
            or not -MAX_MOVE <= distance <= MAX_MOVE
        ):
            raise ValueError(
                f"Move distance must be between -{MAX_MOVE:g} and {MAX_MOVE:g} metres"
            )

    elif name == "turn":
        degrees = args.get("degrees")

        if (
            isinstance(degrees, bool)
            or not isinstance(degrees, (int, float))
            or not -180 <= degrees <= 180
        ):
            raise ValueError(
                "Turn angle must be between -180 and 180 degrees"
            )

    elif name == "throw":
        distance = args.get("distance")

        if (
            isinstance(distance, bool)
            or not isinstance(distance, (int, float))
            or not 0.5 <= distance <= 4.0
        ):
            raise ValueError(
                "Throw distance must be between 0.5 and 4.0 metres"
            )

    elif name in ("pickup", "drop", "give_up"):
        pass

    else:
        raise ValueError(f"Unknown action: {name}")

    return True
