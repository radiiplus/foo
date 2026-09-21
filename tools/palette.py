from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

palettes = {
    "Verdigris & Ink": [
        ("Background", "#171A19"), ("Linking words", "#B98286"), ("Type words", "#C5A86A"),
        ("Types", "#79B7A5"), ("Functions", "#D18F63"), ("Strings", "#9FBE9A"), ("Comments", "#78827E")
    ],
    "Ink & Cinnabar": [
        ("Background", "#171A20"), ("Linking words", "#C56A5D"), ("Type words", "#C8A96B"),
        ("Types", "#9DBBA7"), ("Functions", "#D68B62"), ("Strings", "#AFC1A1"), ("Comments", "#777A78")
    ],
    "Aubergine & Bone": [
        ("Background", "#19151C"), ("Linking words", "#B77F9B"), ("Type words", "#C9B27C"),
        ("Types", "#A5B68A"), ("Functions", "#C88469"), ("Strings", "#9BB4A5"), ("Comments", "#777078")
    ],
    "Petrol & Clay": [
        ("Background", "#141B1B"), ("Linking words", "#B87870"), ("Type words", "#C4A86C"),
        ("Types", "#8EB5A4"), ("Functions", "#D08A67"), ("Strings", "#A7B68E"), ("Comments", "#778483")
    ],
    "Night Garden": [
        ("Background", "#141917"), ("Linking words", "#B77F91"), ("Type words", "#C5AD70"),
        ("Types", "#87A982"), ("Functions", "#D19A63"), ("Strings", "#A5B79A"), ("Comments", "#747C75")
    ],
    "Fossil & Mineral": [
        ("Background", "#1C1C1A"), ("Linking words", "#AD7770"), ("Type words", "#BBA16D"),
        ("Types", "#88A99A"), ("Functions", "#B86F4E"), ("Strings", "#A7AF8C"), ("Comments", "#817E72")
    ],
    "Ultramarine & Rust": [
        ("Background", "#17191D"), ("Linking words", "#C06F68"), ("Type words", "#C5A96C"),
        ("Types", "#718FAE"), ("Functions", "#C47C52"), ("Strings", "#A4B092"), ("Comments", "#727A80")
    ],
    "Plum & Verdigris": [
        ("Background", "#19161D"), ("Linking words", "#B77D91"), ("Type words", "#C4A66B"),
        ("Types", "#79AFA0"), ("Functions", "#C47D60"), ("Strings", "#9EAE86"), ("Comments", "#77717B")
    ],
    "Oxidized Parchment": [
        ("Background", "#191A18"), ("Linking words", "#B9787E"), ("Type words", "#C99A69"),
        ("Types", "#D2C39A"), ("Functions", "#D5A76C"), ("Strings", "#9DB79B"), ("Comments", "#77766D")
    ],
}

font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 24)
small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18)
bold = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 27)

W = 1500
row_h = 92
title_h = 70
gap = 32
H = title_h + len(palettes) * (title_h + 7 * row_h + gap)

img = Image.new("RGB", (W, H), "#101110")
draw = ImageDraw.Draw(img)

y = 24
for palette_name, colors in palettes.items():
    draw.text((35, y), palette_name, font=bold, fill="#F0ECE2")
    y += title_h - 10

    x = 35
    sw = 145
    for label, hx in colors:
        draw.rounded_rectangle((x, y, x + sw, y + row_h - 18), radius=12, fill=hx)
        draw.text((x + sw + 18, y + 8), label, font=small, fill="#D7D4CB")
        draw.text((x + sw + 18, y + 34), hx, font=small, fill="#8F928B")
        x += 300
        if x > W - 300:
            x = 35
            y += row_h
    y += row_h + gap

path = Path(__file__).resolve().parent.parent / ".artifacts" / "editor" / "palette.png"
path.parent.mkdir(parents=True, exist_ok=True)
img.save(path)
print(path)
