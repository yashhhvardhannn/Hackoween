
class MockClaudeClient:
    def __init__(self):
        self.step = 0
        self.history = []
        self.waiting_for_result = False

        self.actions = [
            ("turn", {"degrees": 30}),
            ("move", {"distance": 1.0}),
            ("turn", {"degrees": -30}),
            ("move", {"distance": 0.5}),
            ("pickup", {}),
            ("turn", {"degrees": 180}),
            ("move", {"distance": 1.0}),
            ("drop", {})
        ]

    def decide(self, command, image_bytes, depth=None):
        if self.waiting_for_result:
            raise RuntimeError(
                "Previous tool result was not recorded"
            )

        if not image_bytes:
            raise ValueError("Camera image is missing")

        if self.step >= len(self.actions):
            return {
                "name": "give_up",
                "arguments": {
                    "reason": "Mock sequence finished"
                },
                "input_tokens": 0,
                "output_tokens": 0
            }

        name, args = self.actions[self.step]

        self.history.append({
            "type": "decision",
            "step": self.step + 1,
            "command": command,
            "action": name
        })

        self.waiting_for_result = True

        return {
            "name": name,
            "arguments": {
                **args,
                "observation": (
                    "Mock camera observation"
                ),
                "reasoning": (
                    "Predefined action for integration testing"
                )
            },
            "input_tokens": 0,
            "output_tokens": 0
        }

    def record_result(self, result):
        if not self.waiting_for_result:
            raise RuntimeError(
                "No pending tool call"
            )

        self.history.append({
            "type": "tool_result",
            "result": result
        })

        self.waiting_for_result = False
        self.step += 1
