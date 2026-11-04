
import json
from pathlib import Path

BUDGET_FILE = Path("runs/budget.json")

TARGET_BUDGET = 40.0
WARNING_LIMIT = 30.0
SONNET_SAFETY_LIMIT = 34.0
MAX_DEVELOPMENT_RUNS = 120

# Example rates only, in USD per million tokens.
# Replace with the organizer's actual model pricing.
PRICING = {
    "sonnet": {
        "input": 3.0,
        "output": 15.0
    },
    "haiku": {
        "input": 1.0,
        "output": 5.0
    }
}


class BudgetTracker:
    def __init__(self):
        BUDGET_FILE.parent.mkdir(
            parents=True, exist_ok=True
        )

        if BUDGET_FILE.exists():
            self.data = json.loads(
                BUDGET_FILE.read_text(encoding="utf-8")
            )
        else:
            self.data = {
                "total_cost": 0.0,
                "development_runs": 0,
                "runs": []
            }
            self.save()

    def save(self):
        BUDGET_FILE.write_text(
            json.dumps(self.data, indent=2),
            encoding="utf-8"
        )

    def estimate_cost(
        self, model, input_tokens, output_tokens
    ):
        rates = PRICING[model]

        input_cost = (
            input_tokens / 1_000_000
        ) * rates["input"]

        output_cost = (
            output_tokens / 1_000_000
        ) * rates["output"]

        return input_cost + output_cost

    def can_start_run(
        self, model="sonnet", force=False,
        development=True
    ):
        if not development:
            return True

        if self.data["total_cost"] >= WARNING_LIMIT:
            print("WARNING: Development budget reached.")

        if self.data["development_runs"] >= MAX_DEVELOPMENT_RUNS:
            print("Development run limit reached.")
            return False

        if (
            model == "sonnet"
            and self.data["total_cost"] >= SONNET_SAFETY_LIMIT
            and not force
        ):
            print("Sonnet safety limit reached.")
            return False

        if self.data["total_cost"] >= WARNING_LIMIT:
            print("Reserve remaining credits for final testing.")
            return False

        return True

    def record_run(self, run_id, cost, development=True):
        self.data["total_cost"] += cost

        if development:
            self.data["development_runs"] += 1

        self.data["runs"].append({
            "run_id": run_id,
            "cost": round(cost, 6),
            "development": development
        })

        self.save()

    def show_summary(self):
        total = self.data["total_cost"]

        print("\n--- CLAUDE API BUDGET ---")
        print(f"Spent: ${total:.4f}")
        print(f"Remaining target: ${max(0, TARGET_BUDGET-total):.4f}")
        print(
            f"Development runs: "
            f"{self.data['development_runs']}"
        )
        print("-------------------------\n")
