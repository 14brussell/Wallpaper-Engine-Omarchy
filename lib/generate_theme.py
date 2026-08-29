#!/usr/bin/env python3
"""Generate an accessible Omarchy colors.toml from a wallpaper image."""

from __future__ import annotations

import colorsys
import math
import sys
from pathlib import Path

try:
    from PIL import Image, ImageOps
except ImportError as exc:  # pragma: no cover - exercised by the CLI guard
    raise SystemExit("Auto-match requires python-pillow (package: python-pillow).") from exc


RGB = tuple[int, int, int]


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def hls(rgb: RGB) -> tuple[float, float, float]:
    r, g, b = (channel / 255 for channel in rgb)
    return colorsys.rgb_to_hls(r, g, b)


def from_hls(hue: float, lightness: float, saturation: float) -> RGB:
    rgb = colorsys.hls_to_rgb(hue % 1.0, clamp(lightness), clamp(saturation))
    return tuple(round(channel * 255) for channel in rgb)  # type: ignore[return-value]


def mix(first: RGB, second: RGB, amount: float) -> RGB:
    amount = clamp(amount)
    return tuple(round(a * (1 - amount) + b * amount) for a, b in zip(first, second))  # type: ignore[return-value]


def relative_luminance(rgb: RGB) -> float:
    def linear(channel: int) -> float:
        value = channel / 255
        return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4

    r, g, b = (linear(channel) for channel in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(first: RGB, second: RGB) -> float:
    lighter, darker = sorted((relative_luminance(first), relative_luminance(second)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def ensure_contrast(color: RGB, background: RGB, minimum: float, lighten: bool) -> RGB:
    hue, lightness, saturation = hls(color)
    for _ in range(24):
        candidate = from_hls(hue, lightness, saturation)
        if contrast(candidate, background) >= minimum:
            return candidate
        lightness = clamp(lightness + (0.025 if lighten else -0.025))
    return from_hls(hue, 0.98 if lighten else 0.02, saturation)


def circular_hue_distance(first: float, second: float) -> float:
    distance = abs(first - second)
    return min(distance, 1 - distance)


def quantized_palette(image: Image.Image) -> list[tuple[RGB, int]]:
    sample = image.copy()
    sample.thumbnail((256, 256), Image.Resampling.LANCZOS)
    quantized = sample.quantize(colors=24, method=Image.Quantize.MEDIANCUT)
    raw_palette = quantized.getpalette() or []
    counts = quantized.getcolors(maxcolors=256) or []
    result: list[tuple[RGB, int]] = []
    for count, index in sorted(counts, reverse=True):
        offset = index * 3
        if offset + 2 < len(raw_palette):
            result.append(((raw_palette[offset], raw_palette[offset + 1], raw_palette[offset + 2]), count))
    return result or [((32, 32, 32), 1)]


def choose_accent(palette: list[tuple[RGB, int]], background: RGB, light_mode: bool) -> RGB:
    total = max(1, sum(count for _, count in palette))

    def score(entry: tuple[RGB, int]) -> float:
        color, count = entry
        _, lightness, saturation = hls(color)
        usable_lightness = 1 - abs(lightness - (0.38 if light_mode else 0.62))
        return saturation * 1.7 + usable_lightness * 0.45 + math.sqrt(count / total) * 0.35

    color = max(palette, key=score)[0]
    hue, lightness, saturation = hls(color)
    saturation = clamp(max(saturation, 0.48), high=0.82)
    if light_mode:
        lightness = clamp(lightness, 0.30, 0.46)
        candidate = from_hls(hue, lightness, saturation)
        return ensure_contrast(candidate, background, 3.2, lighten=False)
    lightness = clamp(lightness, 0.55, 0.72)
    candidate = from_hls(hue, lightness, saturation)
    return ensure_contrast(candidate, background, 3.2, lighten=True)


def semantic_color(
    palette: list[tuple[RGB, int]], target_hue: float, light_mode: bool, background: RGB
) -> RGB:
    candidates = []
    for color, count in palette:
        hue, lightness, saturation = hls(color)
        if saturation >= 0.18:
            score = circular_hue_distance(hue, target_hue) - min(count, 10000) / 250000
            candidates.append((score, hue, lightness, saturation))
    if candidates:
        _, hue, _, saturation = min(candidates)
        # Do not let a distant wallpaper hue turn a semantic red into blue.
        if circular_hue_distance(hue, target_hue) > 0.13:
            hue = target_hue
    else:
        hue, saturation = target_hue, 0.62
    saturation = clamp(max(saturation, 0.50), high=0.78)
    lightness = 0.39 if light_mode else 0.66
    candidate = from_hls(hue, lightness, saturation)
    return ensure_contrast(candidate, background, 3.0, lighten=not light_mode)


def as_hex(rgb: RGB) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb)


def build_palette(image: Image.Image) -> dict[str, str]:
    palette = quantized_palette(image)
    total = max(1, sum(count for _, count in palette))
    average_luminance = sum(relative_luminance(color) * count for color, count in palette) / total
    bright_share = sum(count for color, count in palette if relative_luminance(color) > 0.62) / total
    light_mode = average_luminance > 0.68 and bright_share > 0.58

    dominant = palette[0][0]
    base_hue, _, base_saturation = hls(dominant)
    base_saturation = min(base_saturation * 0.45, 0.20)
    background = from_hls(base_hue, 0.94 if light_mode else 0.105, base_saturation)
    accent = choose_accent(palette, background, light_mode)
    foreground = from_hls(base_hue, 0.10 if light_mode else 0.92, min(base_saturation + 0.04, 0.18))
    foreground = ensure_contrast(foreground, background, 7.0, lighten=not light_mode)

    if light_mode:
        dark_background = from_hls(base_hue, 0.89, base_saturation)
        darker_background = from_hls(base_hue, 0.84, base_saturation)
        lighter_background = from_hls(base_hue, 0.97, base_saturation)
        selection = mix(background, accent, 0.18)
        muted = mix(background, foreground, 0.33)
        dark_foreground = mix(background, foreground, 0.46)
        light_foreground = mix(background, foreground, 0.78)
    else:
        dark_background = from_hls(base_hue, 0.075, base_saturation)
        darker_background = from_hls(base_hue, 0.045, base_saturation)
        lighter_background = from_hls(base_hue, 0.16, min(base_saturation + 0.04, 0.24))
        selection = mix(background, accent, 0.30)
        muted = mix(background, foreground, 0.34)
        dark_foreground = mix(background, foreground, 0.44)
        light_foreground = mix(background, foreground, 0.78)

    semantic_hues = {
        "red": 0.00,
        "orange": 0.075,
        "yellow": 0.135,
        "green": 0.34,
        "cyan": 0.50,
        "blue": 0.61,
        "magenta": 0.88,
        "brown": 0.065,
    }
    semantic = {
        name: semantic_color(palette, hue, light_mode, background)
        for name, hue in semantic_hues.items()
    }

    result: dict[str, RGB | str] = {
        "mode": "light" if light_mode else "dark",
        "accent": accent,
        "selection": selection,
        "muted": muted,
        "background": background,
        "dark_background": dark_background,
        "darker_background": darker_background,
        "lighter_background": lighter_background,
        "foreground": foreground,
        "dark_foreground": dark_foreground,
        "light_foreground": light_foreground,
        "bright_foreground": foreground,
        **semantic,
    }
    for name in ("red", "yellow", "green", "cyan", "blue", "magenta"):
        color = semantic[name]
        hue, lightness, saturation = hls(color)
        bright_lightness = max(0.49, lightness - 0.04) if light_mode else min(0.80, lightness + 0.12)
        result[f"bright_{name}"] = from_hls(hue, bright_lightness, saturation)
    return {key: value if isinstance(value, str) else as_hex(value) for key, value in result.items()}


def write_theme(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    backgrounds = destination / "backgrounds"
    backgrounds.mkdir(parents=True, exist_ok=True)

    with Image.open(source) as opened:
        image = ImageOps.exif_transpose(opened).convert("RGB")
        palette = build_palette(image)
        background = image.copy()
        background.thumbnail((3840, 2160), Image.Resampling.LANCZOS)
        background.save(backgrounds / "wallpaper.jpg", "JPEG", quality=92, optimize=True)

    ordered = [
        "accent", "selection", "muted", "background", "dark_background",
        "darker_background", "lighter_background", "foreground", "dark_foreground",
        "light_foreground", "bright_foreground", "red", "yellow", "orange",
        "green", "cyan", "blue", "magenta", "brown", "bright_red",
        "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta",
    ]
    lines = [f'mode = "{palette["mode"]}"', ""]
    for name in ordered:
        lines.append(f'{name} = "{palette[name]}"')
    (destination / "colors.toml").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (destination / ".wallpaper-engine-omarchy-generated").write_text(
        "Generated by Wallpaper Engine Omarchy.\n", encoding="utf-8"
    )


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: generate_theme.py <wallpaper-image> <theme-directory>", file=sys.stderr)
        return 2
    source = Path(sys.argv[1]).expanduser().resolve()
    destination = Path(sys.argv[2]).expanduser().resolve()
    if not source.is_file():
        print(f"Wallpaper image does not exist: {source}", file=sys.stderr)
        return 1
    try:
        write_theme(source, destination)
    except (OSError, ValueError) as exc:
        print(f"Could not generate theme: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
