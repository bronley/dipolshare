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

transfer = source_file("LocalSendTransfer.m")
json_adapter = source_file("LocalSendJSON.m")
jsonkit = project / "Vendor/JSONKit/JSONKit.m"
headers = [source_file(name).parent for name in (
    "LocalSendTransfer.h", "LocalSendHTTPSClient.h",
    "LocalSendIdentityStore.h", "LocalSendSounds.h", "LocalSendJSON.h")]
headers.append(jsonkit.parent)

with tempfile.TemporaryDirectory(prefix="localsend-sending-tests-") as build:
    executable = Path(build) / "sending-tests"
    command = ["xcrun", "clang", "-fno-objc-arc", "-Wno-deprecated-declarations",
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
        "-framework", "Foundation", "-framework", "Security",
        "-I", str(tests / "Stubs")]
    for directory in sorted(set(headers)):
        command += ["-I", str(directory)]
    command += [str(transfer), str(json_adapter), str(jsonkit),
        str(tests / "sending_tests.m"), "-o", str(executable)]
    subprocess.run(command, check=True)
    subprocess.run([str(executable)], check=True)
