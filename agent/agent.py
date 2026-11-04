
import argparse
import os
import time
from dotenv import load_dotenv

load_dotenv()

from agent import budget
from agent.budget import BudgetTracker
from agent.claude_client import MODEL
from datetime import datetime

from agent.tools import (
    get_state,
    get_image,
    execute_action,
    validate_action,
    get_depth,
    start_run,
    end_run,
    reset_scene,
)
from agent.logger import RunLogger


MAX_STEPS = 60


def dummy_decision(step):
    actions = [
        ("turn", {"degrees": 30}),
        ("move", {"distance": 1.0}),
        ("turn", {"degrees": -30}),
        ("move", {"distance": 0.5}),
        ("pickup", {}),
        ("turn", {"degrees": 180}),
        ("move", {"distance": 1.0}),
        ("drop", {})
    ]

    if step >= len(actions):
        return None

    return {
        "name": actions[step][0],
        "arguments": actions[step][1]
    }


def run_agent(command, mode, reset=False):
    run_id = datetime.now().strftime(
        "%Y%m%d_%H%M%S"
    )

    logger = RunLogger(run_id)
    budget = BudgetTracker()
    run_cost = 0.0
    collision_count = 0

    print("\nROBOT AGENT STARTED")
    print("Mode:", mode)
    print("Command:", command)
    print("Run ID:", run_id)

    if reset:
        reset_scene()
        print("Scene reset to start positions")

    start_run(command, run_id)
    outcome = "fail_not_reached"

    claude = None
    try:
        if mode == "claude":
            if not os.getenv("ANTHROPIC_API_KEY"):
                raise RuntimeError(
                    "ANTHROPIC_API_KEY is not set. "
                    "Use --mode dummy for testing."
                )
            from agent.claude_client import ClaudeRobotClient
            claude = ClaudeRobotClient()
        elif mode == "mock":
            from agent.mock_claude import MockClaudeClient
            claude = MockClaudeClient()
        elif mode == "openrouter":
            # Any OpenRouter model with image + tool support; development only, not judged runs.
            from agent.openrouter_client import OpenRouterRobotClient, MODEL as OR_MODEL
            claude = OpenRouterRobotClient()
            print("OpenRouter model:", OR_MODEL)
        elif mode == "vision":
            # No-API stand-in that reads the camera pixels; for testing only, not judged runs.
            from agent.vision_brain import VisionBrain
            claude = VisionBrain()

        for step in range(MAX_STEPS):
            image = get_image()
            depth = get_depth()

            if mode == "dummy":
                decision = dummy_decision(step)
                if decision is None:
                    break
            else:
                decision = claude.decide(command, image, depth)
                if mode == "claude":
                    model_type = "haiku" if "haiku" in MODEL.lower() else "sonnet"
                    step_cost = budget.estimate_cost(
                        model_type,
                        decision["input_tokens"],
                        decision["output_tokens"],
                    )
                    run_cost += step_cost
                    print(f"Estimated API cost: ${step_cost:.6f}")

            action = decision["name"]
            arguments = decision["arguments"]
            print(f"\nSTEP {step + 1}")
            print("Action:", action)
            print("Arguments:", arguments)

            if action == "give_up":
                if mode in ("mock", "claude", "vision", "openrouter"):
                    claude.record_result({
                        "gave_up": True,
                        "reason": arguments.get("reason", ""),
                    })
                print("Agent gave up:", arguments.get("reason"))
                break

            engine_args = {}
            if action == "turn":
                engine_args["degrees"] = arguments["degrees"]
            elif action == "move":
                engine_args["distance"] = arguments["distance"]
            elif action not in ("pickup", "drop"):
                raise ValueError(f"Unknown action: {action}")

            try:
                validate_action(action, engine_args)
                result = execute_action(action, engine_args)
            except (ValueError, KeyError) as error:
                result = {
                    "success": False,
                    "error": str(error),
                    "action_rejected": True,
                }
                print("Action rejected:", error)

            if result.get("collided") is True:
                collision_count += 1
                print(f"Collision detected! Total: {collision_count}")
            elif action == "move" and result.get("collided") is False:
                collision_count = 0

            if collision_count >= 3:
                print("WARNING: Three consecutive collisions. Robot may be stuck.")

            if mode in ("mock", "claude", "vision", "openrouter"):
                claude.record_result(result)

            logger.save_step(
                step=step + 1,
                image_bytes=image,
                tool=action,
                args=engine_args,
                result=result,
                observation=arguments.get("observation", "Camera not analysed"),
                reasoning=arguments.get("reasoning", "Predefined action for testing"),
            )
            print("Result:", result)
            print("Logged successfully")

            if result.get("state") == "Done":
                outcome = "fail_collision" if result.get("collided") else "fail_not_reached"
                print("Engine ended the run.")
                break

            if action == "drop" and result.get("success") and result.get("in_zone"):
                print("\nDelivery confirmed!")
                outcome = "pass"
                break
            time.sleep(0.5)

        if mode == "claude":
            budget.record_run(run_id, run_cost)
            budget.show_summary()
        print("\nRUN COMPLETED")
        print("Logs saved in:", logger.run_folder)
    finally:
        end_run(outcome)


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "command",
        nargs="?",
        default="Bring the red cube"
    )

    parser.add_argument(
        "--mode",
        choices=["dummy", "mock", "claude", "vision", "openrouter"],
        default="dummy"
    )

    parser.add_argument(
        "--reset",
        action="store_true",
        help="put the robot and objects back at their start positions first",
    )

    args = parser.parse_args()

    run_agent(args.command, args.mode, reset=args.reset)


if __name__ == "__main__":
    main()
