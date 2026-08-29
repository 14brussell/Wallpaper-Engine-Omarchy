#!/usr/bin/env python3

import importlib.util
import tempfile
import tomllib
import unittest
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("generate_theme", ROOT / "lib/generate_theme.py")
assert SPEC and SPEC.loader
THEME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(THEME)


class AutoThemeGeneratorTest(unittest.TestCase):
    def test_generates_complete_accessible_theme_and_background(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "wallpaper.png"
            output = root / "theme"
            image = Image.new("RGB", (320, 180))
            for y in range(image.height):
                for x in range(image.width):
                    image.putpixel(
                        (x, y),
                        (
                            12 + round(38 * x / image.width),
                            20 + round(50 * y / image.height),
                            55 + round(150 * x / image.width),
                        ),
                    )
            image.save(source)

            THEME.write_theme(source, output)
            colors = tomllib.loads((output / "colors.toml").read_text())
            required = {
                "mode", "accent", "selection", "muted", "background",
                "dark_background", "darker_background", "lighter_background",
                "foreground", "dark_foreground", "light_foreground",
                "bright_foreground", "red", "yellow", "orange", "green",
                "cyan", "blue", "magenta", "brown", "bright_red",
                "bright_yellow", "bright_green", "bright_cyan", "bright_blue",
                "bright_magenta",
            }
            self.assertEqual(required, set(colors))
            self.assertTrue((output / "backgrounds/wallpaper.jpg").is_file())
            self.assertTrue((output / ".wallpaper-engine-omarchy-generated").is_file())

            def rgb(value):
                return tuple(int(value[index:index + 2], 16) for index in (1, 3, 5))

            self.assertGreaterEqual(
                THEME.contrast(rgb(colors["foreground"]), rgb(colors["background"])),
                7.0,
            )
            self.assertGreaterEqual(
                THEME.contrast(rgb(colors["accent"]), rgb(colors["background"])),
                3.0,
            )


if __name__ == "__main__":
    unittest.main()
