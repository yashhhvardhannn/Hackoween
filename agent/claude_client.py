import json
import base64
import os

from anthropic import Anthropic

from agent.prompts import SYSTEM_PROMPT
from tools.leak_check import check_request


MODEL = os.getenv(
    "CLAUDE_MODEL",
    "claude-sonnet-5-5"
)


ROBOT_TOOLS = [
    {
        "name": "turn",
        "description": "Rotate the robot in degrees: positive = right, negative = left. Allowed range -180 to 180.",
        "input_schema": {
            "type": "object",
            "properties": {
                "degrees": {"type": "number"},
                "observation": {"type": "string"},
                "reasoning": {"type": "string"}
            },
            "required": [
                "degrees", "observation", "reasoning"
            ]
        }
    },
    {
        "name": "move",
        "description": "Move the robot in metres: positive = forward, negative = backward. Allowed range -1.5 to 1.5 per step.",
        "input_schema": {
            "type": "object",
            "properties": {
                "distance": {"type": "number"},
                "observation": {"type": "string"},
                "reasoning": {"type": "string"}
            },
            "required": [
                "distance", "observation", "reasoning"
            ]
        }
    },
    {
        "name": "pickup",
        "description": "Attempt to pick up an object.",
        "input_schema": {
            "type": "object",
            "properties": {
                "observation": {"type": "string"},
                "reasoning": {"type": "string"}
            },
            "required": [
                "observation", "reasoning"
            ]
        }
    },
    {
        "name": "drop",
        "description": "Attempt to drop the held object.",
        "input_schema": {
            "type": "object",
            "properties": {
                "observation": {"type": "string"},
                "reasoning": {"type": "string"}
            },
            "required": [
                "observation", "reasoning"
            ]
        }
    },
    {
        "name": "throw",
        "description": "Throw the held object straight ahead so it lands about this many metres in front of the robot. Allowed range 0.5 to 4.0. It may bounce or roll a little after landing.",
        "input_schema": {
            "type": "object",
            "properties": {
                "distance": {"type": "number"},
                "observation": {"type": "string"},
                "reasoning": {"type": "string"}
            },
            "required": [
                "distance", "observation", "reasoning"
            ]
        }
    },
    {
        "name": "give_up",
        "description": "Stop when the task cannot be completed.",
        "input_schema": {
            "type": "object",
            "properties": {
                "reason": {"type": "string"}
            },
            "required": ["reason"]
        }
    }
]

CACHED_TOOLS = [
    *ROBOT_TOOLS[:-1],
    {
        **ROBOT_TOOLS[-1],
        "cache_control": {"type": "ephemeral"},
    },
]


NO_NEW_IMAGE = (
    "No new camera image: the robot has not moved or turned since the last one, "
    "so the view is unchanged. Use the last image and the tool result."
)


class ClaudeRobotClient:
    def __init__(self):
        self.client = Anthropic()
        self.history = []
        self.pending_tool_id = None

    def decide(self, command, image_bytes, depth=None):
        if self.pending_tool_id is not None:
            raise RuntimeError(
                "Previous tool result has not been recorded"
            )

        if image_bytes is None:
            # Brief: no second image without a move/turn in between; keep the last image as is.
            current_content = [{
                "type": "text",
                "text": (
                    f"Task: {command}\n"
                    f"{NO_NEW_IMAGE} Choose exactly one robot action."
                ),
            }]
            return self._ask(command, current_content)

        encoded_image = base64.b64encode(
            image_bytes
        ).decode("utf-8")

        current_content = [
            {
                "type": "text",
                "text": (
                    f"Task: {command}\n"
                    f"Latest depth reading: {depth!r}\n"
                    "Here is the latest camera image. "
                    "Choose exactly one robot action."
                )
            },
            {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": encoded_image
                }
            }
        ]

        # Keep prior turns as compact text. Only the current camera frame is
        # sent as an image, preventing image-token costs from multiplying.
        for message in self.history:
            if message.get("role") != "user":
                continue
            old_content = message.get("content")
            if isinstance(old_content, list) and any(
                block.get("type") == "image"
                for block in old_content
                if isinstance(block, dict)
            ):
                message["content"] = [
                    {
                        "type": "text",
                        "text": "Earlier camera frame: reviewed; use the latest frame.",
                    }
                ]

        return self._ask(command, current_content)

    def _ask(self, command, current_content):
        self.history.append({
            "role": "user",
            "content": current_content
        })

        request = {
            "system": SYSTEM_PROMPT,
            "tools": CACHED_TOOLS,
            "messages": self.history,
        }
        check_request(request, command)

        response = self.client.messages.create(
            model=MODEL,
            max_tokens=500,
            system=[{
                "type": "text",
                "text": SYSTEM_PROMPT,
                "cache_control": {"type": "ephemeral"},
            }],
            tools=CACHED_TOOLS,
            tool_choice={"type": "any"},
            messages=self.history
        )

        tool_calls = [
            block for block in response.content
            if block.type == "tool_use"
        ]

        if len(tool_calls) != 1:
            self.history.pop()
            raise RuntimeError(
                "Expected exactly one robot action"
            )

        action = tool_calls[0]

        self.history.append({
            "role": "assistant",
            "content": [
                block.model_dump()
                for block in response.content
            ]
        })

        self.pending_tool_id = action.id

        return {
            "name": action.name,
            "arguments": action.input,
            "input_tokens": response.usage.input_tokens,
            "output_tokens": response.usage.output_tokens
        }

    def record_result(self, result):
        if self.pending_tool_id is None:
            raise RuntimeError(
                "No pending tool call to record"
            )

        self.history.append({
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": self.pending_tool_id,
                    "content": json.dumps(result)
                }
            ]
        })

        self.pending_tool_id = None

