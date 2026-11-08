#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

tests = Path(__file__).resolve().parent
project = tests.parent.parent

def source_file(name):
    matches = list(project.rglob(name))
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one {name}, found {len(matches)}")
    return matches[0]

transfer = source_file("Transfer.m")
json_adapter = source_file("JSON.m")
jsonkit = project / "Vendor/JSONKit/JSONKit.m"
headers = [source_file(name).parent for name in (
    "Transfer.h", "HTTPSClient.h",
    "IdentityStore.h", "Sounds.h", "JSON.h",
    "Discovery.h")]
headers.append(jsonkit.parent)

with tempfile.TemporaryDirectory(prefix="localsend-sending-tests-") as build:
    executable = Path(build) / "sending-tests"
    command = ["xcrun", "clang", "-fno-objc-arc", "-Wno-deprecated-declarations",
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
        "-framework", "Foundation", "-framework", "Security", "-framework", "CoreServices",
        "-I", str(tests / "Stubs")]
    for directory in sorted(set(headers)):
        command += ["-I", str(directory)]
    command += [str(transfer)] + [str(p) for p in sorted(transfer.parent.glob("Transfer+*.m"))]
    command += [str(json_adapter), str(jsonkit),
        str(tests / "sending_tests.m"), "-o", str(executable)]
    subprocess.run(command, check=True)
    subprocess.run([str(executable)], check=True)
