# Sendspin iOS Player — Cross-Compilation Build Guide

## 1. Environment Setup (Ubuntu 22.04 / WSL)

Install required system tools:
```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    clang \
    llvm-14 \
    lld \
    cmake \
    libssl-dev \
    libplist-dev \
    pkg-config \
    uuid-dev \
    autoconf \
    automake \
    libtool \
    zip \
    dpkg-dev
```

---

## 2. Toolchain & SDK Configuration

1. **iOS SDK:**
   Place `iPhoneOS9.3.sdk` or `iPhoneOS10.3.sdk` in `/opt/sdks/`.
2. **Theos Clang Toolchain:**
   Installed in `/opt/theos/toolchain/linux/iphone/ios-arm64e-clang-toolchain/bin/`.
3. **CCTools & Apple libtapi:**
   Installed in `/opt/cctools/` (`arm-apple-darwin11-ld`).
4. **Code-signing utility:**
   `ldid` installed in `/usr/local/bin/ldid`.

---

## 3. Compilation Commands

To build the complete `.ipa` and `.deb` packages:
```bash
cd sendspin-ios
chmod +x build.sh
./build.sh
```

To run all automated tests:
```bash
python tests/run_all_tests.py
```
