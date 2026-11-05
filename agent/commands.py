"""Recognise the kind of task a typed command asks for."""

THROW_WORDS = ("throw", "toss", "fling", "lob", "chuck")


def is_free_throw(command: str) -> bool:
    """True for commands like "Pick up any object and throw it".

    A free throw lands anywhere: the run passes as soon as the throw succeeds.
    A command that mentions the drop zone ("throw it into the zone") is a normal
    delivery instead, and only passes when the object lands in the zone.
    """
    text = command.lower()
    return any(w in text for w in THROW_WORDS) and "zone" not in text
