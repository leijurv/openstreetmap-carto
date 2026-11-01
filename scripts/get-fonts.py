#!/usr/bin/env python3
# This script downloads several Noto fonts from https://github.com/notofonts/noto-fonts
# That repo was archived in 2023 and is no longer updated.
# Additional fonts can be found on https://notofonts.github.io

import hashlib
import os
import requests
import tempfile
import shutil
import warnings
import zipfile

FONTDIR = os.environ.get("FONTDIR", "./fonts")

# Expected SHA-256 of every downloaded file, keyed by destination file name, in
# sha256sum format.  All download sources of a file must serve identical bytes.
# Check installed fonts with: cd fonts && sha256sum -c --ignore-missing ../scripts/get-fonts.sha256
HASHFILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "get-fonts.sha256")
with open(HASHFILE) as f:
    SHA256 = {name: digest for digest, name in (line.split() for line in f if line.strip())}

# Seconds without a response before a download source is given up on
TIMEOUT = 60

try:
    os.mkdir(FONTDIR)
except FileExistsError:
    warnings.warn("Font directory already exists")

# Fonts to download in regular, bold, and italic
REGULAR_BOLD_ITALIC = ["NotoSans"]

# Fonts to download in regular and bold
REGULAR_BOLD = [
    "NotoSansAdlamUnjoined",
    "NotoSansArabicUI",
    "NotoSansArmenian",
    "NotoSansBalinese",
    "NotoSansBamum",
    "NotoSansBengaliUI",
    "NotoSansCanadianAboriginal",
    "NotoSansCham",
    "NotoSansCherokee",
    "NotoSansDevanagariUI",
    "NotoSansEthiopic",
    "NotoSansGeorgian",
    "NotoSansGujaratiUI",
    "NotoSansGurmukhiUI",
    "NotoSansHebrew",
    "NotoSansJavanese",
    "NotoSansKannadaUI",
    "NotoSansKayahLi",
    "NotoSansKhmerUI",
    "NotoSansLaoUI",
    "NotoSansLisu",
    "NotoSansMalayalamUI",
    "NotoSansMyanmarUI",
    "NotoSansOlChiki",
    "NotoSansOriyaUI",
    "NotoSansSinhalaUI",
    "NotoSansSundanese",
    "NotoSansSymbols",
    "NotoSansTaiTham",
    "NotoSansTamilUI",
    "NotoSansTeluguUI",
    "NotoSansThaana",
    "NotoSansThaiUI",
    "NotoSerifTibetan",
]

# Fonts to download regular and black, but no bold
REGULAR_BLACK = ["NotoSansSyriac"]

# Fonts to download only regular
REGULAR = [
    "NotoSansBatak",
    "NotoSansBuginese",
    "NotoSansBuhid",
    "NotoSansChakma",
    "NotoSansCoptic",
    "NotoSansHanunoo",
    "NotoSansLepcha",
    "NotoSansLimbu",
    "NotoSansMandaic",
    "NotoSansMongolian",
    "NotoSansNewTaiLue",
    "NotoSansNKo",
    "NotoSansOsage",
    "NotoSansOsmanya",
    "NotoSansSamaritan",
    "NotoSansSaurashtra",
    "NotoSansShavian",
    "NotoSansSymbols2",
    "NotoSansTagalog",
    "NotoSansTagbanwa",
    "NotoSansTaiLe",
    "NotoSansTaiViet",
    "NotoSansTifinagh",
    "NotoSansVai",
    "NotoSansYi",
]


# Attempt to download the font from repos in this order
def findFontUrls(fontName, modifier):
    return [
        f"https://github.com/notofonts/noto-fonts/raw/main/hinted/ttf/{fontName}/{fontName}-{modifier}.ttf",
        # currently only sourcing from one repo
    ]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# Try the urls in order until one serves the file with the expected hash.  The
# destination is only written after that, so a failed run keeps existing files.
def downloadToFile(urls, destination, dir=FONTDIR):
    headers = {"User-Agent": "get-fonts.py/osm-carto"}
    path = os.path.join(dir, destination)
    if destination not in SHA256:
        raise Exception(f"No SHA-256 for {destination} in {HASHFILE}")
    expected = SHA256[destination]

    if os.path.isfile(path):
        with open(path, "rb") as f:
            if sha256(f.read()) == expected:
                return

    errors = []
    for url in urls:
        try:
            r = requests.get(url, headers=headers, timeout=TIMEOUT)
            if r.status_code != 200:
                error = f"HTTP {r.status_code}"
            elif sha256(r.content) != expected:
                error = f"SHA-256 {sha256(r.content)} does not match {expected}"
            else:
                with open(path + ".part", "wb") as f:
                    f.write(r.content)
                os.replace(path + ".part", path)
                return
        except requests.RequestException as e:
            error = str(e)
        warnings.warn(f"Failed to download {url}: {error}")
        errors.append(f"{url}: {error}")

    raise Exception(f"Failed to download {destination} from any source:\n" + "\n".join(errors))


for font in REGULAR_BOLD + REGULAR_BOLD_ITALIC + REGULAR_BLACK + REGULAR:
    regularFontUrls = findFontUrls(font, "Regular")
    downloadToFile(regularFontUrls, f"{font}-Regular.ttf")

    if (font in REGULAR_BOLD) or (font in REGULAR_BOLD_ITALIC):
        boldFontUrls = findFontUrls(font, "Bold")
        downloadToFile(boldFontUrls, f"{font}-Bold.ttf")

    if font in REGULAR_BOLD_ITALIC:
        italicFontUrls = findFontUrls(font, "Italic")
        downloadToFile(italicFontUrls, f"{font}-Italic.ttf")

    if font in REGULAR_BLACK:
        blackFontUrls = findFontUrls(font, "Black")
        downloadToFile(blackFontUrls, f"{font}-Black.ttf")

# Other noto fonts which don't follow the URL pattern above

# CJK fonts
downloadToFile(
    [
        "https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/Japanese/NotoSansCJKjp-Regular.otf"
    ],
    "NotoSansCJKjp-Regular.otf",
)
downloadToFile(
    [
        "https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/Japanese/NotoSansCJKjp-Bold.otf"
    ],
    "NotoSansCJKjp-Bold.otf",
)

# Fonts in zipfiles need a temporary directory
TMPDIR = tempfile.mkdtemp(prefix="get-fonts.")

# Noto Emoji B&W isn't available as a separate download, so we need to download the package and unzip it
downloadToFile(
    ["https://archive.org/download/noto-emoji/Noto_Emoji.zip"],
    "Noto_Emoji.zip",
    dir=TMPDIR,
)
emojiPath = os.path.join(TMPDIR, "Noto_Emoji.zip")
emojiExtract = ["NotoEmoji-Regular.ttf", "NotoEmoji-Bold.ttf"]
with zipfile.ZipFile(emojiPath, "r") as zip_ref:
    for file in emojiExtract:
        source = zip_ref.getinfo(f"static/{file}")
        zip_ref.extract(source, FONTDIR)
        # move from FONTDIR/static/x to overwrite FONTDIR/x
        unzipSrc = os.path.join(FONTDIR, file)
        if os.path.exists(unzipSrc):
            os.remove(unzipSrc)
        shutil.move(os.path.join(FONTDIR, "static", file), FONTDIR)

downloadToFile(
    ["https://mirrors.dotsrc.org/osdn/hanazono-font/68253/hanazono-20170904.zip"],
    "hanazono.zip",
    dir=TMPDIR,
)
hanazonoPath = os.path.join(TMPDIR, "hanazono.zip")
with zipfile.ZipFile(hanazonoPath, "r") as zip_ref:
    for file in ["HanaMinA.ttf", "HanaMinB.ttf"]:
        source = zip_ref.getinfo(file)
        zip_ref.extract(source, FONTDIR)

# clean up tmp directories
shutil.rmtree(TMPDIR)
fontdir_static = os.path.join(FONTDIR, "static")
if os.path.exists(fontdir_static):
    shutil.rmtree(fontdir_static)
