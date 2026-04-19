"""Generate the Vaux app icon — a bold geometric V with a green-teal gradient on dark background."""

from PIL import Image, ImageDraw, ImageFilter
import math

SIZE = 1024
PADDING = 180

def lerp_color(c1, c2, t):
    return tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))

def create_icon():
    img = Image.new("RGBA", (SIZE, SIZE), (13, 13, 20, 255))

    # Subtle radial glow behind the V
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    cx, cy = SIZE // 2, SIZE // 2 + 40
    for r in range(300, 0, -2):
        alpha = int(35 * (1 - r / 300))
        glow_draw.ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            fill=(0, 229, 122, alpha)
        )
    glow = glow.filter(ImageFilter.GaussianBlur(40))
    img = Image.alpha_composite(img, glow)

    # V shape coordinates
    # The V is a thick filled polygon
    top_y = PADDING + 40
    bottom_y = SIZE - PADDING - 20
    left_x = PADDING + 20
    right_x = SIZE - PADDING - 20
    center_x = SIZE // 2
    bar_w = 110  # half-width of V arms

    # Outer V vertices
    outer = [
        (left_x, top_y),                          # top-left outer
        (center_x - 48, bottom_y),                # bottom-left
        (center_x + 48, bottom_y),                # bottom-right
        (right_x, top_y),                         # top-right outer
    ]
    # Inner V vertices (cutout)
    inner_top_offset = bar_w * 2
    inner = [
        (right_x - inner_top_offset, top_y),      # top-right inner
        (center_x, bottom_y - 200),               # bottom center inner
        (left_x + inner_top_offset, top_y),       # top-left inner
    ]
    # Full polygon: outer left-top → bottom-left → bottom-right → outer right-top → inner right-top → inner bottom → inner left-top
    v_poly = outer + inner

    # Create gradient V
    v_mask = Image.new("L", (SIZE, SIZE), 0)
    mask_draw = ImageDraw.Draw(v_mask)
    mask_draw.polygon(v_poly, fill=255)

    # Gradient from green to teal (top-left to bottom-right)
    gradient = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    green = (0, 229, 122)
    teal = (0, 212, 255)
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x / SIZE * 0.5 + y / SIZE * 0.5)
            t = max(0, min(1, t))
            c = lerp_color(green, teal, t)
            gradient.putpixel((x, y), (*c, 255))

    # Apply V mask to gradient
    v_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    v_layer.paste(gradient, mask=v_mask)

    # Add subtle inner shadow / depth to V
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.polygon(v_poly, fill=(0, 0, 0, 60))
    shadow = shadow.filter(ImageFilter.GaussianBlur(8))
    # Offset shadow slightly
    shadow_offset = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_offset.paste(shadow, (4, 6))

    img = Image.alpha_composite(img, shadow_offset)
    img = Image.alpha_composite(img, v_layer)

    # Subtle top highlight on the V
    highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    h_mask = Image.new("L", (SIZE, SIZE), 0)
    h_draw = ImageDraw.Draw(h_mask)
    h_draw.polygon(v_poly, fill=255)
    # Only keep top portion
    h_draw.rectangle([0, top_y + 120, SIZE, SIZE], fill=0)
    for y in range(SIZE):
        for x in range(SIZE):
            if h_mask.getpixel((x, y)) > 0:
                alpha = int(40 * max(0, 1 - (y - top_y) / 120))
                highlight.putpixel((x, y), (255, 255, 255, alpha))
    img = Image.alpha_composite(img, highlight)

    return img.convert("RGB")

if __name__ == "__main__":
    icon = create_icon()
    out = "/home/user/fitness_coach/Vaux/Vaux/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    icon.save(out, "PNG")
    print(f"Icon saved to {out} ({icon.size[0]}x{icon.size[1]})")
