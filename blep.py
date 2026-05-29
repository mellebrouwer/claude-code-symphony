"""A tiny module that emits a friendly blep.

A "blep" is the affectionate term for when a small animal leaves the very tip
of its tongue poking out. This module produces one on demand.
"""


def blep(times: int = 2) -> str:
    """Return a blep, optionally repeated.

    Args:
        times: How many bleps to string together. Must be >= 1.

    Returns:
        A string containing the requested number of bleps.

    Raises:
        ValueError: If ``times`` is less than 1.
    """
    if times < 1:
        raise ValueError("times must be at least 1")
    return " ".join(["blep"] * times)


def main() -> None:
    print(blep())


if __name__ == "__main__":
    main()
