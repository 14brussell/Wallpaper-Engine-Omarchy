#!/usr/bin/env python3
"""Generic virtual-desktop canvas helpers for Wallpaper Engine Omarchy.

All geometry comes from the caller (hyprctl monitors -j at apply time).
No monitor names, resolutions, or wallpaper ids are hardcoded.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any

STILL_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
GIF_EXTS = {".gif"}
IMAGE_EXTS = STILL_EXTS | GIF_EXTS
PREVIEW_BASENAMES = {
    "preview.jpg",
    "preview.jpeg",
    "preview.png",
    "preview.webp",
    "preview.gif",
    "preview_small.jpg",
    "thumb.jpg",
    "thumbnail.jpg",
}
SKIP_DIR_NAMES = {".git", "node_modules", "__pycache__", ".cache"}


def _have_pil() -> bool:
    try:
        from PIL import Image  # noqa: F401

        return True
    except Exception:
        return False


def _magick_bin() -> str | None:
    for name in ("magick", "convert"):
        if _which(name):
            return name
    return None


def _which(name: str) -> str | None:
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def _identify_dims(path: str) -> tuple[int, int] | None:
    ext = os.path.splitext(path)[1].lower()
    if _have_pil():
        from PIL import Image

        try:
            with Image.open(path) as im:
                try:
                    im.seek(0)
                except EOFError:
                    pass
                return int(im.size[0]), int(im.size[1])
        except Exception:
            pass
    identify = _which("identify")
    if identify:
        try:
            # First frame only — multi-frame GIF/WebP would otherwise concatenate.
            target = f"{path}[0]" if ext in {".gif", ".webp"} else path
            out = subprocess.check_output(
                [identify, "-format", "%w %h\\n", target],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
            first = out.splitlines()[0]
            w, h = first.split()[:2]
            return int(w), int(h)
        except Exception:
            pass
    return None


def layout_from_hypr(monitors: list[dict[str, Any]]) -> dict[str, Any]:
    """Build a bounding-box canvas from hyprctl (or similar) monitor objects.

    Uses name, x, y, width, height as reported. Missing x/y (wlr-randr) packs
    outputs left-to-right in enumeration order. Scale is recorded but geometry
    is the compositor's pixel layout — grim -o captures physical pixels.
    """
    outs: list[dict[str, Any]] = []
    cursor_x = 0
    for m in monitors or []:
        name = str(m.get("name") or "").strip()
        if not name:
            continue
        try:
            w = int(m.get("width") or 0)
            h = int(m.get("height") or 0)
        except (TypeError, ValueError):
            w, h = 0, 0
        if w <= 0 or h <= 0:
            continue
        if "x" in m and m["x"] is not None:
            try:
                x = int(m["x"])
            except (TypeError, ValueError):
                x = cursor_x
        else:
            x = cursor_x
        if "y" in m and m["y"] is not None:
            try:
                y = int(m["y"])
            except (TypeError, ValueError):
                y = 0
        else:
            y = 0
        try:
            scale = float(m.get("scale") or 1) or 1.0
        except (TypeError, ValueError):
            scale = 1.0
        outs.append(
            {
                "name": name,
                "x": x,
                "y": y,
                "width": w,
                "height": h,
                "scale": scale,
                "transform": m.get("transform", 0),
            }
        )
        cursor_x = x + w

    if not outs:
        raise SystemExit("no monitors with width/height in layout")

    min_x = min(o["x"] for o in outs)
    min_y = min(o["y"] for o in outs)
    max_x = max(o["x"] + o["width"] for o in outs)
    max_y = max(o["y"] + o["height"] for o in outs)
    return {
        "min_x": min_x,
        "min_y": min_y,
        "width": max_x - min_x,
        "height": max_y - min_y,
        "monitors": outs,
    }


def _cover_crop_pil(src: str, w: int, h: int, mode: str):
    from PIL import Image

    im = Image.open(src)
    try:
        im.seek(0)
    except EOFError:
        pass
    im = im.convert("RGB")
    if mode == "stretch":
        return im.resize((w, h), Image.Resampling.LANCZOS)
    iw, ih = im.size
    if iw <= 0 or ih <= 0:
        return Image.new("RGB", (w, h), (0, 0, 0))
    if mode == "fit":
        scale = min(w / iw, h / ih)
        nw = max(1, int(iw * scale))
        nh = max(1, int(ih * scale))
        resized = im.resize((nw, nh), Image.Resampling.LANCZOS)
        canvas = Image.new("RGB", (w, h), (0, 0, 0))
        canvas.paste(resized, ((w - nw) // 2, (h - nh) // 2))
        return canvas
    # fill / default: cover
    if iw == w and ih == h:
        return im
    scale = max(w / iw, h / ih)
    nw = max(1, int(round(iw * scale)))
    nh = max(1, int(round(ih * scale)))
    resized = im.resize((nw, nh), Image.Resampling.LANCZOS)
    left = max(0, (nw - w) // 2)
    top = max(0, (nh - h) // 2)
    return resized.crop((left, top, left + w, top + h))


def _cover_magick(src: str, w: int, h: int, dest: str, mode: str) -> None:
    magick = _magick_bin()
    if not magick:
        raise SystemExit("need Pillow or ImageMagick to scale stills")
    src_arg = src
    if os.path.splitext(src)[1].lower() in GIF_EXTS:
        src_arg = f"{src}[0]"
    size = f"{w}x{h}"
    if mode == "stretch":
        args = [magick, src_arg, "-resize", f"{size}!", dest]
    elif mode == "fit":
        args = [
            magick,
            src_arg,
            "-resize",
            size,
            "-gravity",
            "center",
            "-background",
            "black",
            "-extent",
            size,
            dest,
        ]
    else:
        args = [
            magick,
            src_arg,
            "-resize",
            f"{size}^",
            "-gravity",
            "center",
            "-extent",
            size,
            dest,
        ]
    subprocess.check_call(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def crop_xywh(src: str, x: int, y: int, w: int, h: int, dest: str) -> None:
    """Crop SRC at (x,y,w,h) in image pixels. Used to slice per-output FROM from a full grim."""
    x, y, w, h = int(x), int(y), int(w), int(h)
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    if _have_pil():
        from PIL import Image

        im = Image.open(src).convert("RGB")
        iw, ih = im.size
        x = max(0, min(x, max(0, iw - 1)))
        y = max(0, min(y, max(0, ih - 1)))
        w = max(1, min(w, iw - x))
        h = max(1, min(h, ih - y))
        _save(im.crop((x, y, x + w, y + h)), dest)
        return
    magick = _magick_bin()
    if not magick:
        raise SystemExit("need Pillow or ImageMagick to crop")
    subprocess.check_call(
        [magick, src, "-crop", f"{w}x{h}+{x}+{y}", "+repage", dest],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def cover(src: str, w: int, h: int, dest: str, mode: str = "fill") -> None:
    mode = (mode or "fill").lower()
    if mode in ("default", "", "none"):
        mode = "fill"
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    if _have_pil():
        im = _cover_crop_pil(src, w, h, mode)
        _save(im, dest)
        return
    _cover_magick(src, w, h, dest, mode)


def _save(im: Any, dest: str) -> None:
    ext = os.path.splitext(dest)[1].lower()
    kwargs: dict[str, Any] = {}
    if ext in {".jpg", ".jpeg"}:
        kwargs.update(quality=92, optimize=True)
    im.save(dest, **kwargs)


def compose(layout: dict[str, Any], regions: list[dict[str, Any]], dest: str) -> None:
    w = int(layout["width"])
    h = int(layout["height"])
    min_x = int(layout["min_x"])
    min_y = int(layout["min_y"])
    by_name = {
        str(r.get("name") or ""): str(r.get("path") or "")
        for r in (regions or [])
        if r.get("name") and r.get("path")
    }
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)

    if _have_pil():
        from PIL import Image

        canvas = Image.new("RGB", (w, h), (0, 0, 0))
        for mon in layout.get("monitors") or []:
            name = str(mon.get("name") or "")
            path = by_name.get(name)
            if not path or not os.path.isfile(path):
                continue
            mw, mh = int(mon["width"]), int(mon["height"])
            filled = _cover_crop_pil(path, mw, mh, "fill")
            x = int(mon["x"]) - min_x
            y = int(mon["y"]) - min_y
            canvas.paste(filled, (x, y))
        _save(canvas, dest)
        return

    magick = _magick_bin()
    if not magick:
        raise SystemExit("need Pillow or ImageMagick to compose canvases")
    tmp = dest + ".canvas.tmp.png"
    subprocess.check_call(
        [magick, "-size", f"{w}x{h}", "xc:black", tmp],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        for mon in layout.get("monitors") or []:
            name = str(mon.get("name") or "")
            path = by_name.get(name)
            if not path or not os.path.isfile(path):
                continue
            mw, mh = int(mon["width"]), int(mon["height"])
            x = int(mon["x"]) - min_x
            y = int(mon["y"]) - min_y
            region = dest + f".region.{name}.jpg"
            _cover_magick(path, mw, mh, region, "fill")
            subprocess.check_call(
                [
                    magick,
                    tmp,
                    region,
                    "-geometry",
                    f"+{x}+{y}",
                    "-composite",
                    tmp,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                os.remove(region)
            except OSError:
                pass
        subprocess.check_call(
            [magick, tmp, dest],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def _is_preview_name(path: str, extra_exclude: set[str] | None = None) -> bool:
    base = os.path.basename(path).lower()
    if base in PREVIEW_BASENAMES:
        return True
    if extra_exclude and os.path.realpath(path) in extra_exclude:
        return True
    return False


def best_still(directory: str, allow_preview: bool = False) -> str | None:
    """Largest raster in a workshop folder.

    jpg/png/webp/bmp win when they are at least as large as any gif. Gif is
    included after that so scene packs with only preview.gif still resolve.
    Preview basenames are last resort.
    """
    extra: set[str] = set()
    project = os.path.join(directory, "project.json")
    if os.path.isfile(project):
        try:
            data = json.loads(open(project, encoding="utf-8").read())
        except Exception:
            data = {}
        preview = str(data.get("preview") or data.get("preview_image") or "")
        if preview:
            p = preview if os.path.isabs(preview) else os.path.join(directory, preview)
            if os.path.isfile(p):
                extra.add(os.path.realpath(p))

    # (area, preferred_still, w, h, path) — preferred_still ranks jpg/png/webp
    # above gif at the same area so gif is only used after larger stills.
    ranked: list[tuple[int, int, int, int, str]] = []
    for root, dirs, files in os.walk(directory):
        depth = os.path.relpath(root, directory).count(os.sep)
        if root != directory:
            depth += 1
        if depth > 6:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if d not in SKIP_DIR_NAMES and not d.startswith(".")]
        for fname in files:
            ext = os.path.splitext(fname)[1].lower()
            if ext not in IMAGE_EXTS:
                continue
            path = os.path.join(root, fname)
            if not allow_preview and _is_preview_name(path, extra):
                continue
            dims = _identify_dims(path)
            if not dims:
                continue
            w, h = dims
            is_gif = ext in GIF_EXTS
            # Keep gif / last-resort preview even when smaller than 64px —
            # ffmpeg can scale those; skip only tiny leftover still rasters.
            if not is_gif and not allow_preview and (w < 64 or h < 64):
                continue
            if w < 1 or h < 1:
                continue
            preferred = 0 if is_gif else 1
            ranked.append((w * h, preferred, w, h, path))
    ranked.sort(reverse=True)
    if ranked:
        return ranked[0][4]
    # Never fall back to preview.jpg as a TO still. Callers that want the
    # workshop thumbnail must pass allow_preview=True (--allow-preview).
    return None


def fbo_paint_state(path: str, epsilon: int = 8) -> str:
    """Classify an LWE FBO dump as painted, clear, or incomplete.

    LWE cannot present a first frame without a black clear. Do not use mean
    brightness — a dark wallpaper is painted. Structure = max>epsilon or
    any channel range / stddev above the clear floor. Opening an image is not
    enough to call it clear: LWE writes JPEGs in place, and their metadata can
    be readable before a full pixel decode succeeds.
    """
    if not path or not os.path.isfile(path):
        return "incomplete"
    try:
        if os.path.getsize(path) < 32:
            return "incomplete"
    except OSError:
        return "incomplete"
    try:
        eps = max(0, int(epsilon))
    except (TypeError, ValueError):
        eps = 8
    if _have_pil():
        from PIL import Image, ImageStat

        try:
            with Image.open(path) as im:
                im = im.convert("RGB")
                im.thumbnail((128, 128))
                st = ImageStat.Stat(im)
        except Exception:
            return "incomplete"
        mx = max(ch[1] for ch in st.extrema)
        mn = min(ch[0] for ch in st.extrema)
        sd = max(st.stddev) if st.stddev else 0.0
        painted = mx > eps or (mx - mn) > eps or sd > 2.0
        return "painted" if painted else "clear"
    identify = _which("identify")
    if not identify:
        return "incomplete"
    try:
        out = subprocess.check_output(
            [identify, "-format", "%[fx:maxima] %[fx:standard_deviation]\\n", path],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip().split()
        if len(out) < 2:
            return "incomplete"
        maxima = float(out[0])
        stddev = float(out[1])
    except Exception:
        return "incomplete"
    painted = maxima > (eps / 255.0) or stddev > 0.01
    return "painted" if painted else "clear"


def fbo_has_paint(path: str, epsilon: int = 8) -> bool:
    """Compatibility predicate for callers that only need painted/not-painted."""
    return fbo_paint_state(path, epsilon) == "painted"


def _load_json_arg(raw: str) -> Any:
    if raw == "-" or raw == "/dev/stdin":
        return json.load(sys.stdin)
    if os.path.isfile(raw):
        with open(raw, encoding="utf-8") as f:
            return json.load(f)
    return json.loads(raw)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Virtual-desktop canvas helpers")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("layout", help="stdin: hyprctl monitors -j → layout JSON")
    d = sub.add_parser("dims", help="print WIDTH HEIGHT")
    d.add_argument("path")
    v = sub.add_parser("verify", help="exit 0 if image is WxH")
    v.add_argument("path")
    v.add_argument("width", type=int)
    v.add_argument("height", type=int)
    c = sub.add_parser("cover", help="scale/crop SRC into DEST at WxH")
    c.add_argument("src")
    c.add_argument("width", type=int)
    c.add_argument("height", type=int)
    c.add_argument("dest")
    c.add_argument("--mode", default="fill")
    b = sub.add_parser("best-still", help="largest non-preview raster in DIR")
    b.add_argument("directory")
    b.add_argument("--allow-preview", action="store_true")
    k = sub.add_parser("compose", help="paste per-output stills onto layout canvas")
    k.add_argument("layout")
    k.add_argument("regions")
    k.add_argument("dest")
    r = sub.add_parser("crop", help="crop SRC at X Y W H into DEST")
    r.add_argument("src")
    r.add_argument("x", type=int)
    r.add_argument("y", type=int)
    r.add_argument("width", type=int)
    r.add_argument("height", type=int)
    r.add_argument("dest")
    t = sub.add_parser("painted", help="exit 0 if LWE FBO dump has structure (not uniform ~0)")
    t.add_argument("path")
    t.add_argument("--epsilon", type=int, default=8)
    s = sub.add_parser("paint-state", help="print painted, clear, or incomplete for an LWE FBO dump")
    s.add_argument("path")
    s.add_argument("--epsilon", type=int, default=8)

    args = p.parse_args(argv)

    if args.cmd == "layout":
        monitors = json.load(sys.stdin)
        json.dump(layout_from_hypr(monitors), sys.stdout, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0

    if args.cmd == "dims":
        dims = _identify_dims(args.path)
        if not dims:
            return 1
        print(f"{dims[0]} {dims[1]}")
        return 0

    if args.cmd == "verify":
        dims = _identify_dims(args.path)
        if not dims:
            return 1
        ok = dims[0] == args.width and dims[1] == args.height
        print(f"{dims[0]} {dims[1]}")
        return 0 if ok else 1

    if args.cmd == "cover":
        cover(args.src, args.width, args.height, args.dest, args.mode)
        return 0

    if args.cmd == "best-still":
        path = best_still(args.directory, allow_preview=args.allow_preview)
        if not path:
            return 1
        print(path)
        return 0

    if args.cmd == "compose":
        layout = _load_json_arg(args.layout)
        regions = _load_json_arg(args.regions)
        compose(layout, regions, args.dest)
        return 0

    if args.cmd == "crop":
        crop_xywh(args.src, args.x, args.y, args.width, args.height, args.dest)
        return 0

    if args.cmd == "painted":
        return 0 if fbo_has_paint(args.path, args.epsilon) else 1

    if args.cmd == "paint-state":
        print(fbo_paint_state(args.path, args.epsilon))
        return 0

    return 2


if __name__ == "__main__":
    sys.exit(main())
