#!/usr/bin/env python3
#
#  generate_cydia_repo.py
#  Generates universal Cydia / Sileo / Zebra APT repository metadata
#  Supports both flat repo (./) and standard Debian pool (dists/) layouts
#

import os
import sys
import glob
import hashlib
import gzip
import bz2
import lzma
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

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    os.makedirs(os.path.join(OUTPUT_DIR, "debs"), exist_ok=True)
    
    # 1. Copy static web assets
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

    # 2. Collect .deb files
    deb_files = []
    # Check repo/debs
    for f in glob.glob(os.path.join(DEBS_DIR, "*.deb")):
        dest = os.path.join(OUTPUT_DIR, "debs", os.path.basename(f))
        shutil.copy2(f, dest)
        deb_files.append(dest)
    
    # Check root of repo
    for f in glob.glob(os.path.join(REPO_ROOT, "*.deb")):
        dest = os.path.join(OUTPUT_DIR, "debs", os.path.basename(f))
        shutil.copy2(f, dest)
        if dest not in deb_files:
            deb_files.append(dest)

    print(f"[Cydia-Repo] Found {len(deb_files)} Debian package(s) for repository.")

    # Also copy debs to root of OUTPUT_DIR for direct flat URL resolution
    for deb in deb_files:
        fn = os.path.basename(deb)
        shutil.copy2(deb, os.path.join(OUTPUT_DIR, fn))

    # 3. Build Packages file (Strict Unix LF line endings)
    packages_entries = []

    for deb in deb_files:
        filename = os.path.basename(deb)
        dest_path = os.path.join(OUTPUT_DIR, "debs", filename)
        hashes = get_file_hashes(dest_path)
        
        # Package metadata paragraph
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
            f"Filename: ./debs/{filename}",
            f"Size: {hashes['size']}",
            f"MD5sum: {hashes['md5']}",
            f"SHA1: {hashes['sha1']}",
            f"SHA256: {hashes['sha256']}",
            "Depiction: https://delliaf.github.io/sendspin-ios/depiction.html",
            "Icon: https://delliaf.github.io/sendspin-ios/CydiaIcon.png"
        ]
        packages_entries.append("\n".join(entry))

    packages_text = "\n\n".join(packages_entries) + "\n\n"
    packages_bytes = packages_text.encode("utf-8")

    # Write Packages files (Root / Flat layout)
    def write_package_archives(target_dir):
        os.makedirs(target_dir, exist_ok=True)
        # Packages
        with open(os.path.join(target_dir, "Packages"), "wb") as f:
            f.write(packages_bytes)
        # Packages.gz
        with gzip.open(os.path.join(target_dir, "Packages.gz"), "wb", compresslevel=9) as f:
            f.write(packages_bytes)
        # Packages.bz2 (Crucial for Cydia on iOS 9)
        with bz2.open(os.path.join(target_dir, "Packages.bz2"), "wb", compresslevel=9) as f:
            f.write(packages_bytes)
        # Packages.xz
        with lzma.open(os.path.join(target_dir, "Packages.xz"), "wb") as f:
            f.write(packages_bytes)

    write_package_archives(OUTPUT_DIR)

    # Also write to dists/ hierarchy for structured APT clients
    for dist in ["ios", "stable"]:
        binary_dir = os.path.join(OUTPUT_DIR, "dists", dist, "main", "binary-iphoneos-arm")
        write_package_archives(binary_dir)

    # 4. Generate Flat Release file (Omit Components for flat repo to prevent APT mismatch)
    files_to_hash = ["Packages", "Packages.gz", "Packages.bz2", "Packages.xz"]
    
    release_lines = [
        "Origin: Delliaf",
        "Label: Sendspin iOS Repo",
        "Suite: stable",
        "Version: 1.0",
        "Codename: sendspin",
        "Architectures: iphoneos-arm iphoneos-arm64",
        "Description: Official Cydia repository for Sendspin iOS Player (iOS 3.0 — iOS 9.3+)",
        "MD5Sum:"
    ]
    for fn in files_to_hash:
        fp = os.path.join(OUTPUT_DIR, fn)
        h = get_file_hashes(fp)
        release_lines.append(f" {h['md5']} {h['size']} {fn}")
        release_lines.append(f" {h['md5']} {h['size']} ./{fn}")

    release_lines.append("SHA1:")
    for fn in files_to_hash:
        fp = os.path.join(OUTPUT_DIR, fn)
        h = get_file_hashes(fp)
        release_lines.append(f" {h['sha1']} {h['size']} {fn}")
        release_lines.append(f" {h['sha1']} {h['size']} ./{fn}")

    release_lines.append("SHA256:")
    for fn in files_to_hash:
        fp = os.path.join(OUTPUT_DIR, fn)
        h = get_file_hashes(fp)
        release_lines.append(f" {h['sha256']} {h['size']} {fn}")
        release_lines.append(f" {h['sha256']} {h['size']} ./{fn}")

    release_content = "\n".join(release_lines) + "\n"
    with open(os.path.join(OUTPUT_DIR, "Release"), "wb") as f:
        f.write(release_content.encode("utf-8"))

    # Also write Release file to dists/ hierarchies
    for dist in ["ios", "stable"]:
        dist_release_lines = [
            "Origin: Delliaf",
            "Label: Sendspin iOS Repo",
            "Suite: " + dist,
            "Version: 1.0",
            "Codename: " + dist,
            "Architectures: iphoneos-arm iphoneos-arm64",
            "Components: main",
            "Description: Official Cydia repository for Sendspin iOS Player (iOS 3.0 — iOS 9.3+)",
            "MD5Sum:"
        ]
        for fn in files_to_hash:
            fp = os.path.join(OUTPUT_DIR, "dists", dist, "main", "binary-iphoneos-arm", fn)
            h = get_file_hashes(fp)
            dist_release_lines.append(f" {h['md5']} {h['size']} main/binary-iphoneos-arm/{fn}")
        dist_release_lines.append("SHA1:")
        for fn in files_to_hash:
            fp = os.path.join(OUTPUT_DIR, "dists", dist, "main", "binary-iphoneos-arm", fn)
            h = get_file_hashes(fp)
            dist_release_lines.append(f" {h['sha1']} {h['size']} main/binary-iphoneos-arm/{fn}")
        dist_release_lines.append("SHA256:")
        for fn in files_to_hash:
            fp = os.path.join(OUTPUT_DIR, "dists", dist, "main", "binary-iphoneos-arm", fn)
            h = get_file_hashes(fp)
            dist_release_lines.append(f" {h['sha256']} {h['size']} main/binary-iphoneos-arm/{fn}")
        
        dist_release_path = os.path.join(OUTPUT_DIR, "dists", dist, "Release")
        with open(dist_release_path, "wb") as f:
            f.write(("\n".join(dist_release_lines) + "\n").encode("utf-8"))

    print("[Cydia-Repo] Universal repository generated successfully (Flat + Dists layouts)!")

if __name__ == "__main__":
    main()
