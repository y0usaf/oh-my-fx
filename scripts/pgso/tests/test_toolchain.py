from __future__ import annotations

import os
import pathlib
import shlex
import tempfile
import unittest
from unittest import mock

from scripts.pgso.model import PgsoError
from scripts.pgso.toolchain import Toolchain


class PgsoToolchainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-toolchain-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)
        self.llvm_bin = self.root / "llvm" / "bin"
        self.system_bin = self.root / "system-bin"
        self.resource_dir = self.root / "llvm" / "lib" / "clang" / "21"
        self.sdk = self.root / "MacOSX.sdk"
        self.profile_runtime = (
            self.resource_dir / "lib" / "darwin" / "libclang_rt.profile_osx.a"
        )
        self.llvm_bin.mkdir(parents=True)
        self.system_bin.mkdir()
        self.profile_runtime.parent.mkdir(parents=True)
        self.profile_runtime.write_bytes(b"profile runtime")
        self.sdk.mkdir()

        self.zig = self.root / "zig"
        self.write_executable(self.zig, "printf '0.16.0\\n'")
        for name in ("opt", "llc", "llvm-profdata", "llvm-ar"):
            self.write_llvm_tool(name)
        self.write_clang()
        for name in ("strip", "codesign", "otool"):
            self.write_executable(self.system_bin / name, "exit 0")
        self.write_executable(
            self.system_bin / "xcrun",
            f"printf '%s\\n' {shlex.quote(str(self.sdk))}",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_executable(self, path: pathlib.Path, body: str) -> None:
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)

    def write_llvm_tool(self, name: str, version: str = "21.1.8") -> None:
        self.write_executable(
            self.llvm_bin / name,
            f"printf 'LLVM version {version}\\n'",
        )

    def write_clang(self, version: str = "21.1.8") -> None:
        body = f"""case "$1" in
  --print-resource-dir) printf '%s\\n' {shlex.quote(str(self.resource_dir))} ;;
  --version) printf 'clang version {version}\\n' ;;
  *) exit 2 ;;
esac"""
        self.write_executable(self.llvm_bin / "clang", body)

    def discover(self) -> Toolchain:
        with mock.patch.dict(
            os.environ,
            {"PATH": str(self.system_bin)},
            clear=False,
        ), mock.patch("platform.system", return_value="Darwin"), mock.patch(
            "platform.machine", return_value="arm64"
        ):
            return Toolchain.discover(
                str(self.zig),
                str(self.llvm_bin),
                "aarch64-macos",
            )

    def test_discover_resolves_the_exact_native_toolchain(self) -> None:
        toolchain = self.discover()

        self.assertEqual(self.zig.resolve(), toolchain.zig)
        self.assertEqual((self.llvm_bin / "opt").resolve(), toolchain.opt)
        self.assertEqual((self.llvm_bin / "llc").resolve(), toolchain.llc)
        self.assertEqual(
            (self.llvm_bin / "llvm-profdata").resolve(),
            toolchain.llvm_profdata,
        )
        self.assertEqual((self.llvm_bin / "llvm-ar").resolve(), toolchain.llvm_ar)
        self.assertEqual((self.llvm_bin / "clang").resolve(), toolchain.clang)
        self.assertEqual((self.system_bin / "strip").resolve(), toolchain.strip)
        self.assertEqual(
            (self.system_bin / "codesign").resolve(),
            toolchain.codesign,
        )
        self.assertEqual((self.system_bin / "otool").resolve(), toolchain.otool)
        self.assertEqual(self.sdk.resolve(), toolchain.sdk)
        self.assertEqual(self.profile_runtime.resolve(), toolchain.profile_runtime)
        self.assertEqual("0.16.0", toolchain.zig_version)
        self.assertEqual("21.1.8", toolchain.llvm_version)
        self.assertEqual("aarch64-macos", toolchain.target)
        self.assertEqual("arm64", toolchain.host_arch)

    def test_discover_rejects_the_wrong_target(self) -> None:
        with self.assertRaisesRegex(PgsoError, "unsupported target: x86_64-macos"):
            Toolchain.discover(str(self.zig), str(self.llvm_bin), "x86_64-macos")

    def test_discover_rejects_a_non_darwin_host(self) -> None:
        with mock.patch("platform.system", return_value="Linux"):
            with self.assertRaisesRegex(PgsoError, "requires a Darwin host"):
                Toolchain.discover(
                    str(self.zig),
                    str(self.llvm_bin),
                    "aarch64-macos",
                )

    def test_discover_rejects_a_non_arm64_host(self) -> None:
        with mock.patch("platform.system", return_value="Darwin"), mock.patch(
            "platform.machine", return_value="x86_64"
        ):
            with self.assertRaisesRegex(PgsoError, "requires an arm64 host"):
                Toolchain.discover(
                    str(self.zig),
                    str(self.llvm_bin),
                    "aarch64-macos",
                )

    def test_discover_rejects_the_wrong_zig_version(self) -> None:
        self.write_executable(self.zig, "printf '0.16.1\\n'")

        with self.assertRaisesRegex(PgsoError, "requires Zig 0.16.0"):
            self.discover()

    def test_discover_rejects_a_mixed_llvm_version(self) -> None:
        self.write_llvm_tool("llc", version="21.1.9")

        with self.assertRaisesRegex(PgsoError, "requires LLVM 21.1.8"):
            self.discover()

    def test_discover_rejects_a_missing_executable(self) -> None:
        (self.llvm_bin / "opt").unlink()

        with self.assertRaisesRegex(PgsoError, "missing executable: opt"):
            self.discover()

    def test_discover_rejects_an_llvm_tool_outside_the_root(self) -> None:
        outside = self.root / "outside-opt"
        self.write_executable(outside, "printf 'LLVM version 21.1.8\\n'")
        (self.llvm_bin / "opt").unlink()
        (self.llvm_bin / "opt").symlink_to(outside)

        with self.assertRaisesRegex(PgsoError, "LLVM tool escapes configured root"):
            self.discover()

    def test_discover_rejects_a_missing_profile_runtime(self) -> None:
        self.profile_runtime.unlink()

        with self.assertRaisesRegex(PgsoError, "missing LLVM profile runtime"):
            self.discover()

    def test_discover_rejects_a_missing_macos_sdk(self) -> None:
        self.sdk.rmdir()

        with self.assertRaisesRegex(PgsoError, "macOS SDK does not exist"):
            self.discover()


if __name__ == "__main__":
    unittest.main()
