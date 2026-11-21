"""Check macOS host pointer state without posting real mouse events."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS and Xcode Swift")
class MacHostPointerTests(unittest.TestCase):
    def test_drag_click_and_session_release(self):
        with tempfile.TemporaryDirectory() as path:
            executable = Path(path) / "pointer-probe"
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "5",
                "Apple/MacHostSources/MHDesktop.swift",
                "Apple/MacHostSources/MHIdentity.swift",
                "Tests/MacHostPointer/PointerProbe.swift",
                "-o", str(executable),
            ], cwd=ROOT, check=True, timeout=90)
            subprocess.run([str(executable)], check=True, timeout=5)
