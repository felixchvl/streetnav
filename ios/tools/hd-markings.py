#!/usr/bin/env python3
"""Writes Streetnav/Features/Map/StreetnavHDMarkings.swift: the HD road markings of Mapbox Standard (lane lines,
crossings, stop lines and road arrows), copied out of the style so that the app draws them again above its own
streets, which would otherwise hide them (they sit in Standard's middle slot, above every road marking).

Standard's style options are replaced by their values (HD roads on, lane colour by default); the layers read the HD
roads tileset from a source of their own. Run it again after Standard changes:

  python3 ios/tools/hd-markings.py
"""
import json
import pathlib
import plistlib
import urllib.request

IOS = pathlib.Path(__file__).resolve().parents[1]
OUT = IOS / "Streetnav/Features/Map/StreetnavHDMarkings.swift"
SOURCE = "streetnav-hd-roads"


def hsla(colour):
    """[hue, saturation, lightness, alpha] of an "hsl(h, s%, l%)" or "hsla(h, s%, l%, a)" string."""
    parts = [float(part.strip().rstrip("%")) for part in colour[colour.index("(") + 1:colour.index(")")].split(",")]
    return parts + [1.0] * (4 - len(parts))


def resolve(value, config):
    """The value with Standard's ["config", name] expressions replaced by the option's value, and the components of a
    constant colour (["to-hsla", colour]) worked out here: once copied, Mapbox converted them wrongly (a lightness of
    105 for 75)."""
    if isinstance(value, list):
        if len(value) == 2 and value[0] == "config" and value[1] in config:
            return config[value[1]]
        if len(value) == 2 and value[0] == "to-hsla":
            colour = resolve(value[1], config)
            if isinstance(colour, str) and colour.startswith("hsl"):
                return ["literal", hsla(colour)]
        return [resolve(item, config) for item in value]
    if isinstance(value, dict):
        return {key: resolve(item, config) for key, item in value.items()}
    return value


def constant(value):
    return not isinstance(value, (list, dict)) or (isinstance(value, list) and value[:1] == ["literal"])


def fold(value, env=None):
    """Works out what only depends on constants: let and var, at on a literal, arithmetic, comparisons and the branch of
    a case. Mapbox checks every branch of a case once all is constant, and refuses one that is never taken (a lightness
    of 75 + 30 when the case only adds 30 to a lightness under 30)."""
    env = env or {}
    if isinstance(value, dict):
        return {key: fold(item, env) for key, item in value.items()}
    if not isinstance(value, list) or not value or not isinstance(value[0], str):
        return [fold(item, env) for item in value] if isinstance(value, list) else value
    op, args = value[0], value[1:]
    if op == "literal":
        return value
    if op == "var" and args[0] in env:
        return env[args[0]]
    if op == "let":
        inner = dict(env)
        kept = []
        for name, bound in zip(args[:-1:2], args[1:-1:2]):
            bound = fold(bound, inner)
            if constant(bound):
                inner[name] = bound
            else:
                kept += [name, bound]
        body = fold(args[-1], inner)
        return ["let", *kept, body] if kept else body
    args = [fold(item, env) for item in args]
    numbers = [arg for arg in args if isinstance(arg, (int, float)) and not isinstance(arg, bool)]
    if op == "at" and isinstance(args[0], int) and isinstance(args[1], list) and args[1][:1] == ["literal"]:
        return args[1][1][args[0]]
    if op in ("+", "-", "*", "/") and len(numbers) == len(args):
        result = numbers[0]
        for number in numbers[1:]:
            result = {"+": result + number, "-": result - number, "*": result * number, "/": result / number}[op]
        return result
    if op in ("<", "<=", ">", ">=", "==", "!=") and len(numbers) == 2 == len(args):
        a, b = numbers
        return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b, "==": a == b, "!=": a != b}[op]
    if op == "case":
        kept = []
        for condition, branch in zip(args[:-1:2], args[1:-1:2]):
            if condition is True and not kept:
                return branch
            if condition is not False:
                kept += [condition, branch]
        return ["case", *kept, args[-1]] if kept else args[-1]
    return [op, *args]


def main():
    token = plistlib.loads((IOS / "Streetnav/Info.plist").read_bytes())["MBXAccessToken"]
    with urllib.request.urlopen(f"https://api.mapbox.com/styles/v1/mapbox/standard?access_token={token}") as response:
        style = json.load(response)
    config = {name: option["default"] for name, option in style["schema"].items()}
    config["showHdRoads"] = True
    source = style["sources"]["mapbox-hd-roads"]["url"]
    layers = []
    for layer in style["layers"]:
        if (layer.get("metadata") or {}).get("mapbox:group") != "hd road markings":
            continue
        if layer["source"] != "mapbox-hd-roads":  # the rails come from the streets tileset
            continue
        layer = fold(resolve(layer, config))
        layer.pop("metadata", None)
        layer.get("layout", {}).pop("visibility", None)
        layer["id"] = "marquages-" + layer["id"]
        layer["source"] = SOURCE
        layer["slot"] = "middle"
        layers.append(layer)
    OUT.write_text(f"""// Generated by ios/tools/hd-markings.py from Mapbox Standard ({style.get("modified", "")[:10]}): do not edit.

/// The HD road markings of Mapbox Standard, drawn again above Streetnav's streets (StreetnavExplorationMap).
enum StreetnavHDMarkings {{
    static let sourceURL = "{source}"
    static let sourceID = "{SOURCE}"
    static let layersJSON = #\"\"\"
{json.dumps(layers, ensure_ascii=False, separators=(",", ":"))}
\"\"\"#
}}
""")
    print(f"{len(layers)} layers written to {OUT.relative_to(IOS)}")


if __name__ == "__main__":
    main()
