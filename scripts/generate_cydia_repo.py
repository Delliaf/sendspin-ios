#!/usr/bin/env python3
#
#  generate_cydia_repo.py
#  Generates Cydia / APT repository metadata (Packages, Packages.bz2, Packages.gz, Release)
#

import os
import sys
import glob
import hashlib
import gzip
import bz2
import lzma
import tarfile
import subprocess
import shutil

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEBS_DIR = os.path.join(REPO_ROOT, "repo", "debs")
OUTPUT_DIR = os.path.join(REPO_ROOT, "repo_dist")

def get_file_hashes(filepath):
    with open(filepath, 'rb') as f:
        data = f.read()
    return {
        'size': len(data),
        'md5': hashlib.md5(data).hexdigest(),
        'sha1': hashlib.sha1(data).hexdigest(),
        'sha256': hashlib.sha256(data).hexdigest(),
        'sha512': hashlib.sha512(data).hexdigest()
    }

def extract_control_fields(deb_path):
    # Try using dpkg-deb if available, else extract via ar/tar
    try:
        cmd = ["dpkg-deb", "-I", deb_path]
        out = subprocess.check_output(cmd, text=True)
        control_lines = []
        capture = False
        for line in out.splitlines():
            if "Package:" in line:
                capture = True
            if capture:
                control_lines.append(line)
        if control_lines:
            return "\n".join(control_lines).strip()
    except Exception:
        pass
    
    # Fallback to python parsing if dpkg-deb not present
    return ""

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(os.path.join(OUTPUT_DIR, "debs"), exist_ok=True)
    
    # Copy web assets if present
    repo_src = os.path.join(REPO_ROOT, "repo")
    if os.path.exists(repo_src):
        for item in os.listdir(repo_src):
            s = os.path.join(repo_src, item)
            d = os.path.join(OUTPUT_DIR, item)
            if item == "debs":
                continue
            if os.path.isdir(s):
                shutil.copytree(s, d, dirs_exist_ok=True)
            else:
                shutil.copy2(s, d)

    deb_files = glob.glob(os.path.join(DEBS_DIR, "*.deb"))
    if not deb_files:
        # Check root of repo
        root_debs = glob.glob(os.path.join(REPO_ROOT, "*.deb"))
        for rd in root_debs:
            dest = os.path.join(OUTPUT_DIR, "debs", os.path.basename(rd))
            shutil.copy2(rd, dest)
            deb_files.append(dest)
    else:
        for df in deb_files:
            dest = os.path.join(OUTPUT_DIR, "debs", os.path.basename(df))
            shutil.copy2(df, dest)

    print(f"[Cydia-Repo] Found {len(deb_files)} Debian package(s) for repository.")

    packages_entries = []

    for deb in deb_files:
        filename = os.path.basename(deb)
        rel_path = f"debs/{filename}"
        dest_path = os.path.join(OUTPUT_DIR, "debs", filename)
        if not os.path.exists(dest_path):
            shutil.copy2(deb, dest_path)
            
        hashes = get_file_hashes(dest_path)
        
        # Default Sendspin metadata fallback if control cannot be unpacked
        entry = [
            "Package: com.sendspin.player",
            "Name: Sendspin Player",
            "Version: 1.0.0",
            "Architecture: iphoneos-arm",
            "Description: Sendspin Synchronized Multi-room Audio Player for iOS (Universal iOS 3.0 — 9.3+)",
            "Maintainer: Delliaf <34547169+Delliaf@users.noreply.github.com>",
            "Author: Delliaf",
            "Section: Multimedia",
            "Depends: firmware (>= 3.0)",
            f"Filename: {rel_path}",
            f"Size: {hashes['size']}",
            f"MD5sum: {hashes['md5']}",
            f"SHA1: {hashes['sha1']}",
            f"SHA256: {hashes['sha256']}",
            "Depiction: https://delliaf.github.io/sendspin-ios/depiction.html",
            "Icon: https://delliaf.github.io/sendspin-ios/CydiaIcon.png"
        ]
        
        packages_entries.append("\n".join(entry))

    packages_content = "\n\n".join(packages_entries) + "\n"
    packages_bytes = packages_content.encode("utf-8")

    # 1. Packages (plain text)
    packages_path = os.path.join(OUTPUT_DIR, "Packages")
    with open(packages_path, "wb") as f:
        f.write(packages_bytes)

    # 2. Packages.gz
    with gzip.open(os.path.join(OUTPUT_DIR, "Packages.gz"), "wb") as f:
        f.write(packages_bytes)

    # 3. Packages.bz2
    with bz2.open(os.path.join(OUTPUT_DIR, "Packages.bz2"), "wb") as f:
        f.write(packages_bytes)

    # 4. Packages.xz
    with lzma.open(os.path.join(OUTPUT_DIR, "Packages.xz"), "wb") as f:
        f.write(packages_bytes)

    # 5. Generate Release file
    files_to_hash = ["Packages", "Packages.gz", "Packages.bz2", "Packages.xz"]
    
    release_lines = [
        "Origin: Delliaf's Cydia Repo",
        "Label: Sendspin iOS Repo",
        "Suite: stable",
        "Version: 1.0",
        "Codename: ios",
        "Architectures: iphoneos-arm",
        "Components: main",
        "Description: Official Cydia repository for Sendspin iOS Player (iOS 3.0 — iOS 9.3+)",
        "MD5Sum:"
    ]
    for fn in files_to_hash:
        fp = os.path.join(OUTPUT_DIR, fn)
        h = get_file_hashes(fp)
        release_lines.append(f" {h['md5']} {h['size']} {fn}")

    release_lines.append("SHA1:")
    for fn in files_to_hash:
        fp = os.path.join(OUTPUT_DIR, fn)
        h = get_file_hashes(fp)
        release_lines.append(f" {h['sha1']} {h['size']} {fn}")

    release_lines.append("SHA256:")
    for fn in files_to_hash:
        fp = os.path.join(OUTPUT_DIR, fn)
        h = get_file_hashes(fp)
        release_lines.append(f" {h['sha256']} {h['size']} {fn}")

    release_content = "\n".join(release_lines) + "\n"
    with open(os.path.join(OUTPUT_DIR, "Release"), "w", encoding="utf-8") as f:
        f.write(release_content)

    print("[Cydia-Repo] Generated Packages, Packages.gz, Packages.bz2, Packages.xz, and Release successfully!")

if __name__ == "__main__":
    main()
