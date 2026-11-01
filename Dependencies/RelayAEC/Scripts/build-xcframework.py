#!/usr/bin/env python3
"""Rebuild RelayAEC using pinned local sources; never modifies the app project.

Requires macOS, Xcode 26+, Python 3.12+, Meson 1.9.0 and Ninja 1.13.0.
All extracted sources, objects, logs and output stay in --work-dir, which must
not exist and must be outside the Relay project. No source network access is
needed. The caller can review and replace the packaged XCFramework afterward.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile


def run(arguments: list[str], log: Path, env: dict[str, str]) -> None:
    with log.open("a") as output:
        output.write("\n" + repr(arguments) + "\n")
        output.flush()
        subprocess.run(arguments, check=True, stdout=output,
                       stderr=subprocess.STDOUT, env=env)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--meson", type=Path, required=True)
    parser.add_argument("--ninja", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if sys.version_info < (3, 12) or sys.platform != "darwin":
        parser.error("Use Python 3.12 or newer on macOS.")
    if args.jobs < 1:
        parser.error("--jobs must be positive.")

    package = Path(__file__).resolve().parents[1]
    project = package.parents[1]
    work = args.work_dir.expanduser().resolve()
    if work == project or work.is_relative_to(project):
        parser.error("--work-dir must be outside the Relay project.")
    if work.exists():
        parser.error("--work-dir must not exist; existing data is never deleted.")
    meson, ninja = args.meson.resolve(strict=True), args.ninja.resolve(strict=True)
    for tool, version in [(meson, "1.9.0"), (ninja, "1.13.0")]:
        actual = subprocess.check_output([str(tool), "--version"], text=True).strip()
        if actual != version:
            parser.error(f"{tool.name} must be {version}; got {actual}.")
    env = os.environ.copy()
    env["PATH"] = f"{meson.parent}:{ninja.parent}:/usr/bin:/bin:/usr/sbin:/sbin"
    # Do not permit a caller's compiler overrides to change this vendor build.
    for variable in ["CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS",
                     "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR"]:
        env.pop(variable, None)
    work.mkdir(parents=True)

    manifest = json.loads((package / "Vendor/SourceManifest.json").read_text())
    archives: dict[str, Path] = {}
    for entry in manifest["sources"]:
        archive = package / "Vendor/Archives" / entry["filename"]
        data = archive.read_bytes()
        if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise SystemExit(f"Pinned source verification failed: {archive.name}")
        archives[archive.name] = archive

    source_archive = archives["webrtc-audio-processing-2.1.tar.xz"]
    with tarfile.open(source_archive) as archive:
        # Pinned source does not require symlinks. Reject them and traversal.
        for member in archive.getmembers():
            target = (work / member.name).resolve()
            if not target.is_relative_to(work) or member.issym() or member.islnk():
                raise SystemExit("Unsafe source archive entry: " + member.name)
        archive.extractall(work, filter="data")
    source = work / "webrtc-audio-processing-2.1"
    cache = source / "subprojects/packagecache"
    cache.mkdir(exist_ok=True)
    for name in ["abseil-cpp-20240722.0.tar.gz", "abseil-cpp_20240722.0-3_patch.zip"]:
        shutil.copy2(archives[name], cache / name)

    host_arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    libraries = []
    for arch in ["arm64", "x86_64"]:
        print(f"Building pinned static audio processor for {arch}…", flush=True)
        build = work / f"build-{arch}"
        flags = ["-arch", arch, "-mmacosx-version-min=26.0"]
        option_file = work / f"{arch}.ini"
        prefix = ""
        cross = arch != host_arch
        if cross:
            family = "aarch64" if arch == "arm64" else "x86_64"
            prefix = ("[binaries]\nc = '/usr/bin/clang'\ncpp = '/usr/bin/clang++'\n"
                      "ar = '/usr/bin/ar'\nstrip = '/usr/bin/strip'\n\n"
                      f"[host_machine]\nsystem = 'darwin'\ncpu_family = '{family}'\n"
                      f"cpu = '{arch}'\nendian = 'little'\n\n")
        option_file.write_text(prefix + "[built-in options]\n" + "\n".join(
            f"{key} = {flags!r}" for key in
            ["c_args", "cpp_args", "c_link_args", "cpp_link_args"]) + "\n")
        log = work / f"Build-{arch}.log"
        setup = [str(meson), "setup", str(build), str(source),
                 "--cross-file" if cross else "--native-file", str(option_file),
                 "--buildtype=release", "--default-library=static",
                 "--wrap-mode=nodownload", "--force-fallback-for=abseil-cpp"]
        if arch == "arm64":
            setup.append("-Dneon=enabled")
        run(setup, log, env)
        run([str(ninja), "-C", str(build), f"-j{args.jobs}"], log, env)
        bridge = work / f"RelayAEC-{arch}.o"
        run(["/usr/bin/clang++", "-std=c++17", "-O2", *flags,
             "-DWEBRTC_POSIX", "-DWEBRTC_MAC", "-DWEBRTC_LIBRARY_IMPL",
             "-I" + str(source / "webrtc"),
             "-I" + str(source / "subprojects/abseil-cpp-20240722.0"),
             "-I" + str(package / "Bridge"), "-c", str(package / "Bridge/RelayAEC.cc"),
             "-o", str(bridge)], log, env)
        # APM's static archive does not absorb static transitive dependencies.
        library = work / f"libRelayAEC-{arch}.a"
        static_dependencies = sorted(build.rglob("*.a"))
        run(["/usr/bin/libtool", "-static", "-o", str(library), str(bridge),
             *map(str, static_dependencies)], log, env)
        libraries.append(library)

    universal = work / "libRelayAEC.a"
    log = work / "Package.log"
    run(["/usr/bin/lipo", "-create", *map(str, libraries), "-output", str(universal)], log, env)
    headers = work / "Headers"
    headers.mkdir()
    shutil.copy2(package / "Bridge/RelayAEC.h", headers / "RelayAEC.h")
    (headers / "module.modulemap").write_text(
        'module RelayAECBinary {\n    header "RelayAEC.h"\n    export *\n}\n')
    output = work / "RelayAEC.xcframework"
    run(["/usr/bin/xcodebuild", "-create-xcframework", "-library", str(universal),
         "-headers", str(headers), "-output", str(output)], log, env)
    print(f"Built {output}\nThe packaged binary was not modified.")


if __name__ == "__main__":
    main()
