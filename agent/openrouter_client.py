"""OpenRouter brain: lets the agent run on any OpenRouter model that accepts images
and tool calls (e.g. DeepSeek V4.1 Flash, or free Gemma 4 / Nemotron VL models).

For development while the team's Claude key is unavailable. Judged runs must use
Claude (--mode claude), as the brief requires.

    .env:  OPENROUTER_API_KEY=sk-or-...
           OPENROUTER_MODEL=deepseek/deepseek-v4.1-flash      (optional, this is the default)

    python -m agent.agent "Bring the yellow cone" --mode openrouter --reset

Same interface as ClaudeRobotClient: decide(command, image, depth) -> one action,
then record_result(result). Same system prompt, same tools, only the latest image
is sent, and the leak check runs before every request.
"""

from __future__ import annotations

import base64
import json
import os
import time

import requests

from agent.claude_client import ROBOT_TOOLS
from agent.prompts import SYSTEM_PROMPT
from tools.leak_check import check_request

API_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = os.getenv("OPENROUTER_MODEL", "deepseek/deepseek-v4.1-flash")
MAX_ATTEMPTS = 3
THINKING = os.getenv("OPENROUTER_THINKING", "1") != "0"

# Same tools as the Claude client, in OpenAI/OpenRouter "function" format.
OPENAI_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": t["name"],
            "description": t["description"],
            "parameters": t["input_schema"],
        },
    }
    for t in ROBOT_TOOLS
]
TOOL_NAMES = {t["name"] for t in ROBOT_TOOLS}


class OpenRouterRobotClient:
    def __init__(self):
        self.api_key = os.getenv("OPENROUTER_API_KEY")
        if not self.api_key:
            raise RuntimeError("OPENROUTER_API_KEY is not set in .env")
        self.history = []
        self.pending_tool_id = None

    def decide(self, command, image_bytes, depth=None):
        if self.pending_tool_id is not None:
            raise RuntimeError("Previous tool result has not been recorded")

        # Only the newest camera frame is sent as an image; older ones become one line of text.
        for message in self.history:
            content = message.get("content")
            if message["role"] == "user" and isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "image_url" for b in content
            ):
                message["content"] = "Earlier camera frame: reviewed; use the latest frame."

        data_url = "data:image/jpeg;base64," + base64.b64encode(image_bytes).decode("utf-8")
        self.history.append({
            "role": "user",
            "content": [
                {"type": "text", "text": (
                    f"Task: {command}\n"
                    f"Latest depth reading: {depth!r}\n"
                    "Here is the latest camera image. Choose exactly one robot action."
                )},
                {"type": "image_url", "image_url": {"url": data_url}},
            ],
        })

        # Leak check on the same content (text only; the image is pixels).
        check_request({"system": SYSTEM_PROMPT, "tools": OPENAI_TOOLS, "messages": self._text_only()}, command)

        body = {
            "model": MODEL,
            # Room for models that "think" before answering; too small a limit gives empty replies.
            "max_tokens": 6000,
            # Hidden "thinking": on by default (5-25 s per step, much better driving).
            # OPENROUTER_THINKING=0 in .env makes steps ~1.5 s, but the model gets lost more often.
            "reasoning": {"effort": "low"} if THINKING else {"enabled": False},
            "messages": [{"role": "system", "content": SYSTEM_PROMPT}] + self.history,
            "tools": OPENAI_TOOLS,
            "tool_choice": "required",
            "parallel_tool_calls": False,
        }
        # Free/cheap models sometimes return an empty reply or hit a rate limit: retry a few times.
        last_problem = ""
        for attempt in range(1, MAX_ATTEMPTS + 1):
            response = requests.post(
                API_URL,
                headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json",
                         "X-Title": "Hackoween robot agent"},
                json=body,
                timeout=120,
            )
            if response.status_code != 200:
                last_problem = f"OpenRouter error {response.status_code}: {response.text[:300]}"
                if response.status_code in (429, 500, 502, 503) and attempt < MAX_ATTEMPTS:
                    print(f"  ({last_problem[:80]}... retrying {attempt}/{MAX_ATTEMPTS - 1})")
                    time.sleep(2 * attempt)
                    continue
                break
            data = response.json()
            choice = (data.get("choices") or [{}])[0]
            message = choice.get("message") or {}
            calls = [c for c in (message.get("tool_calls") or []) if c["function"]["name"] in TOOL_NAMES]
            if calls:
                break
            last_problem = (f"Model did not choose a robot action (finish_reason={choice.get('finish_reason')}). "
                            f"It said: {str(message.get('content'))[:200]}")
            if attempt < MAX_ATTEMPTS:
                print(f"  (empty reply from the model, retrying {attempt}/{MAX_ATTEMPTS - 1})")
        else:
            calls = []
        if response.status_code != 200 or not calls:
            self.history.pop()
            raise RuntimeError(last_problem)
        call = calls[0]                       # exactly one action per step
        try:
            arguments = json.loads(call["function"]["arguments"] or "{}")
        except json.JSONDecodeError:
            arguments = {}

        self.history.append({"role": "assistant", "content": message.get("content") or "", "tool_calls": [call]})
        self.pending_tool_id = call["id"]
        usage = data.get("usage") or {}
        return {
            "name": call["function"]["name"],
            "arguments": arguments,
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        }

    def record_result(self, result):
        if self.pending_tool_id is None:
            raise RuntimeError("No pending tool call to record")
        self.history.append({"role": "tool", "tool_call_id": self.pending_tool_id, "content": json.dumps(result)})
        self.pending_tool_id = None

    def _text_only(self):
        out = []
        for m in self.history:
            c = m.get("content")
            if isinstance(c, list):
                c = [b for b in c if b.get("type") == "text"]
            out.append({"role": m["role"], "content": c})
        return out
