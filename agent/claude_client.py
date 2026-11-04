import json
import base64
import os

from anthropic import Anthropic

from agent.prompts import SYSTEM_PROMPT


MODEL = os.getenv(
    "CLAUDE_MODEL",
    "claude-sonnet-4-5"
)


ROBOT_TOOLS = [
    {
        "name": "turn",
        "description": "Rotate the robot in degrees.",
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
        "description": "Move the robot in metres.",
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


class ClaudeRobotClient:
    def __init__(self):
        self.client = Anthropic()
        self.history = []
        self.pending_tool_id = None

    def decide(self, command, image_bytes):
        if self.pending_tool_id is not None:
            raise RuntimeError(
                "Previous tool result has not been recorded"
            )

        encoded_image = base64.b64encode(
            image_bytes
        ).decode("utf-8")

        content = [
            {
                "type": "text",
                "text": (
                    f"Task: {command}\n"
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

        self.history.append({
            "role": "user",
            "content": content
        })

        response = self.client.messages.create(
            model=MODEL,
            max_tokens=500,
            system=SYSTEM_PROMPT,
            tools=ROBOT_TOOLS,
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

