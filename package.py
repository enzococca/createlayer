#!/usr/bin/env python3
"""Crea il pacchetto ZIP installabile del plugin QField "Create Layer".

Il file main.qml deve trovarsi alla radice dello ZIP (requisito QField).

Genera due copie:
- createlayer.zip (radice del repo): URL stabile "latest"
- releases/<versione>/createlayer.zip: URL versionato, immune alla cache
  del CDN di GitHub (ogni versione ha un URL nuovo)

Uso:
    python package.py
"""

import configparser
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FILES = ["main.qml", "metadata.txt", "icon.svg"]
OUTPUT_ZIP = ROOT / "createlayer.zip"


def plugin_version() -> str:
    cfg = configparser.ConfigParser()
    cfg.read(ROOT / "metadata.txt")
    return cfg["general"]["version"]


def main() -> None:
    for name in FILES:
        if not (ROOT / name).exists():
            raise SystemExit(f"File mancante: {name}")

    with zipfile.ZipFile(OUTPUT_ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in FILES:
            zf.write(ROOT / name, name)

    version = plugin_version()
    versioned_dir = ROOT / "releases" / version
    versioned_dir.mkdir(parents=True, exist_ok=True)
    versioned_zip = versioned_dir / "createlayer.zip"
    shutil.copy2(OUTPUT_ZIP, versioned_zip)

    print(f"Pacchetto creato: {OUTPUT_ZIP}")
    print(f"Pacchetto versionato: {versioned_zip}")
    print("URL installazione (versionato, consigliato):")
    print(f"  https://github.com/enzococca/createlayer/raw/main/releases/{version}/createlayer.zip")


if __name__ == "__main__":
    main()
