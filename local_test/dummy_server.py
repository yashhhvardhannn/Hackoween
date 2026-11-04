
from flask import Flask, jsonify, request, Response
from io import BytesIO
from PIL import Image

app = Flask(__name__)

robot = {
    "state": "Idle",
    "x": 0.0,
    "y": 0.0,
    "heading": 0.0,
    "holding": False,
    "retries": 0
}

@app.get("/state")
def state():
    return jsonify(robot)

@app.get("/look")
def look():
    image = Image.new("RGB", (640, 480), "lightgray")
    buffer = BytesIO()
    image.save(buffer, format="JPEG")
    return Response(buffer.getvalue(), mimetype="image/jpeg")

@app.get("/depth")
def depth():
    return jsonify({"distance": 2.0})

@app.post("/turn")
def turn():
    degrees = request.json["degrees"]
    robot["heading"] = (robot["heading"] + degrees) % 360
    return jsonify({"turned": degrees, "state": robot["state"]})

@app.post("/move")
def move():
    distance = request.json["distance"]
    robot["x"] += distance
    return jsonify({
        "moved": distance,
        "collided": False,
        "state": robot["state"]
    })

@app.post("/pickup")
def pickup():
    robot["holding"] = True
    return jsonify({"success": True})

@app.post("/drop")
def drop():
    robot["holding"] = False
    return jsonify({"success": True, "in_zone": True})

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
