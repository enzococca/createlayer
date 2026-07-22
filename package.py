#!/usr/bin/env python3
"""Crea il pacchetto ZIP installabile del plugin QField "Create Layer".

Il file main.qml deve trovarsi alla radice dello ZIP (requisito QField).

Uso:
    python package.py
"""

import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FILES = ["main.qml", "metadata.txt", "icon.svg"]
OUTPUT_ZIP = ROOT / "createlayer.zip"


def main() -> None:
    for name in FILES:
        if not (ROOT / name).exists():
            raise SystemExit(f"File mancante: {name}")

    with zipfile.ZipFile(OUTPUT_ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in FILES:
            zf.write(ROOT / name, name)

    print(f"Pacchetto creato: {OUTPUT_ZIP}")
    for name in zipfile.ZipFile(OUTPUT_ZIP).namelist():
        print(f"  - {name}")


if __name__ == "__main__":
    main()
