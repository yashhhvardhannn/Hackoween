
import json
from pathlib import Path
from datetime import datetime, timezone
from io import BytesIO
from PIL import Image


class RunLogger:
    def __init__(self, run_id):
        self.run_folder = Path("runs") / run_id
        self.frames_folder = self.run_folder / "frames"

        self.frames_folder.mkdir(
            parents=True,
            exist_ok=True
        )

        self.log_path = self.run_folder / "steps.jsonl"

    def save_step(
        self, step, image_bytes, tool,
        args, result, observation, reasoning
    ):
        frame_name = f"step_{step:03d}.png"
        frame_path = self.frames_folder / frame_name

        image = Image.open(BytesIO(image_bytes))
        image.save(frame_path, format="PNG")

        record = {
            "step": step,
            "timestamp": datetime.now(
                timezone.utc
            ).isoformat(),
            "tool": tool,
            "args": args,
            "result": result,
            "frame_path": f"frames/{frame_name}",
            "observation": observation,
            "reasoning": reasoning
        }

        with open(
            self.log_path, "a", encoding="utf-8"
        ) as file:
            file.write(json.dumps(record) + "\n")

