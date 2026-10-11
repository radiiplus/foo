"""Regenerate the retained 1..128 differential fixtures (no compiler invocation)."""
from pathlib import Path

folder = Path(__file__).with_name("fixtures")
for first in range(1, 129, 16):
    last = first + 15
    definitions = ["use testing as check."]
    checks = []
    for width in range(first, last + 1):
        signed = "integer" if width == 64 else f"integer {width}"
        unsigned = "unsigned" if width == 64 else f"unsigned {width}"
        maximum = (1 << (width - 1)) - 1
        unsigned_maximum = (1 << width) - 1
        for prefix, typ in [("signed", signed), ("unsigned", unsigned)]:
            definitions.append(f"function {prefix}{width}(value {typ}) giving {typ} keeping call {{ give value plus 0. }}")
            multiplier = 0 if width == 1 and prefix == "signed" else 1
            definitions.append(f"function product{prefix}{width}(value {typ}) giving {typ} keeping call {{ give value multiply {multiplier}. }}")
            definitions.append(f"function subtract{prefix}{width}(value {typ}) giving {typ} keeping call {{ give value subtract 0. }}")
            if width > 1 or prefix == "unsigned":
                definitions.append(f"function divide{prefix}{width}(value {typ}) giving {typ} keeping call {{ give value divide 1. }}")
            value = 0 if width == 1 and prefix == "signed" else 1
            for operation in ["", "product", "subtract"]:
                checks.append(f"  check.expect({operation}{prefix}{width}({value}) is {value}).")
            if width > 1 or prefix == "unsigned":
                checks.append(f"  check.expect(divide{prefix}{width}({value}) is {value}).")
        definitions.extend([
            f"function widenSigned{width}(value {signed}) giving integer 128 keeping call {{ give value. }}",
            f"function widenUnsigned{width}(value {unsigned}) giving unsigned 128 keeping call {{ give value. }}",
        ])
        if width == 1:
            checks.append("  eval { constant minimum1 of type integer 1 is 0 subtract 1. }")
        else:
            checks.append(f"  constant minimum{width} of type {signed} is 0 subtract {maximum} subtract 1.")
        checks.extend([
            f"  check.expect(signed{width}(minimum{width}) is minimum{width}).",
            f"  check.expect(signed{width}({maximum}) is {maximum}).",
            f"  check.expect(subtractsigned{width}(minimum{width}) is minimum{width}).",
            f"  check.expect(unsigned{width}({unsigned_maximum}) is {unsigned_maximum}).",
            f"  check.expect(productunsigned{width}({unsigned_maximum}) is {unsigned_maximum}).",
            f"  check.expect(divideunsigned{width}({unsigned_maximum}) is {unsigned_maximum}).",
            f"  check.expect(widenSigned{width}(minimum{width}) is minimum{width}).",
            f"  check.expect(widenUnsigned{width}({unsigned_maximum}) is {unsigned_maximum}).",
        ])
        if width > 1:
            checks.extend([
                f"  check.expect(productsigned{width}(minimum{width}) is minimum{width}).",
                f"  check.expect(dividesigned{width}(minimum{width}) is minimum{width}).",
            ])
    path = folder / f"integers-{first}-{last}.iv"
    path.write_text("\n".join(definitions + ["start {"] + checks + ["}", ""]))
