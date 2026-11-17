#!/usr/bin/env python3
"""Include the actual local GPL source trees, including fork changes, in each app.

An installed .app is not a repository checkout. Shipping a source archive avoids
claiming its recipient already has Vendor/ or relying on a mutable upstream URL.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--app-store-resigning", action="store_true",
                    help="Label executable hashes as build-time provenance; Apple may re-sign the binaries")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
app = args.app
licenses = app / "Contents/Resources/licenses"
licenses.mkdir(parents=True, exist_ok=True)
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
for name in ("ansel-denoise-swift", "hdrmerge-swift"):
    binary = app / "Contents/Resources/bin" / name
    if not binary.is_file():
        continue
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", f"Vendor/{name}"], cwd=root
    ).decode().split("\0")
    paths = sorted({p for p in paths if p and (root / p).is_file()})
    if not paths or f"Vendor/{name}/Package.swift" not in paths:
        raise SystemExit(f"Missing corresponding source for {name}")
    archive = licenses / f"{name}-source.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        for path in paths:
            tar.add(root / path, arcname=path, recursive=False)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    source_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    executable_digest = (
        f"Build-time executable SHA-256 (before App Store re-signing): {digest}\n"
        "Xcode and Apple may re-sign the executable for distribution. This build-time hash is\n"
        "provenance information, not a checksum for the installed executable. The source archive\n"
        "checksum below is independent of code signing.\n"
        if args.app_store_resigning else f"SHA-256: {digest}\n"
    )
    (licenses / f"{name}-SOURCE-OFFER.txt").write_text(
        f"{name} — corresponding source (GPL-3.0-or-later)\n\n"
        f"Executable: Contents/Resources/bin/{name}\n" + executable_digest +
        f"Source archive: Contents/Resources/licenses/{archive.name}\nSHA-256: {source_digest}\n"
        f"Repository revision at packaging: {revision}\n"
        "The archive includes local fork changes present when packaged, including uncommitted source files.\n"
        f"Extract the archive, then run: cd Vendor/{name} && swift build -c release\n"
        "The Swift/macOS SDK toolchain is required; Package.swift describes build inputs.\n"
        "The full GPL license is included beside this notice and inside the source archive.\n"
        "The tool is an independent executable invoked by Photons using files and JSON.\n"
        "Users retain the rights to modify and redistribute this GPL component.\n"
        "Repository and release source: https://github.com/LeoAokma/photons\n"
        + ("\nModel weights, when bundled, are in Contents/Resources/bin/models/. "
           "They are runtime data, separate from this code archive; see ansel-denoise-models.txt.\n"
           if name == "ansel-denoise-swift" else ""), encoding="utf-8")
    print(f"source      {archive.name} ({archive.stat().st_size} bytes)")
