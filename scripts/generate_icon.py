#!/usr/bin/env python3
"""Generate the AppVault app icon as an .iconset directory."""
import os
import sys

from PIL import Image, ImageDraw


def render(size: int) -> Image.Image:
    scale = size / 1024.0
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 深色圆角底板
    radius = int(230 * scale)
    draw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=radius, fill=(26, 30, 37, 255))
    draw.rounded_rectangle(
        [(int(10 * scale), int(10 * scale)), (size - 1 - int(10 * scale), size - 1 - int(10 * scale))],
        radius=max(1, radius - int(10 * scale)),
        outline=(52, 60, 72, 255),
        width=max(1, int(6 * scale)),
    )

    white = (245, 247, 250, 255)
    sway = int(72 * scale)

    # 锁梁
    shackle_box = [
        int(322 * scale), int(214 * scale),
        int(702 * scale), int(594 * scale),
    ]
    draw.arc(shackle_box, start=180, end=360, fill=white, width=sway)

    # 锁体
    body_top = int(470 * scale)
    body = [
        int(252 * scale), body_top,
        int(772 * scale), int(838 * scale),
    ]
    draw.rounded_rectangle(body, radius=int(86 * scale), fill=white)

    # 钥匙孔
    draw.ellipse(
        [
            int(462 * scale), int(576 * scale),
            int(562 * scale), int(676 * scale),
        ],
        fill=(26, 30, 37, 255),
    )
    draw.polygon(
        [
            (int(487 * scale), int(660 * scale)),
            (int(537 * scale), int(660 * scale)),
            (int(548 * scale), int(784 * scale)),
            (int(476 * scale), int(784 * scale)),
        ],
        fill=(26, 30, 37, 255),
    )
    return img


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "build/AppIcon.iconset"
    os.makedirs(out, exist_ok=True)
    variants = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for name, size in variants:
        render(size).save(os.path.join(out, name))
    print(f"iconset written to {out}")


if __name__ == "__main__":
    main()
