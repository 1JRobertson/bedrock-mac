#!/usr/bin/env python3
"""Build and validate a standalone Rosetta/native-ARM batch experiment on macOS.

Default: correctness only. --benchmark additionally requires no running game
(a suspended, separately owned lab game is allowed). Never pauses/kills a game,
changes runtimes, or uses Minecraft data. Terminates only its own probe group.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import signal
import statistics
import subprocess
import tempfile


def game_idle():
    rows = subprocess.check_output(
        ["ps", "-axo", "pid=,stat=,comm="], text=True
    ).splitlines()
    for row in rows:
        fields = row.strip().split(None, 2)
        if len(fields) == 3 and "minecraft.windows.exe" in fields[2].lower():
            if "T" not in fields[1]:
                raise SystemExit("Quit Minecraft before timing; no process was changed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--tuned-m4", action="store_true",
                        help="Compare AVX2-targeted x86 code with Apple-M4-targeted ARM code")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("This experiment requires Apple Silicon macOS with Rosetta.")
    if subprocess.check_output(["sysctl", "-n", "hw.optional.arm64"], text=True).strip() != "1":
        raise SystemExit("This experiment requires Apple Silicon.")
    if args.tuned_m4 and "Apple M4" not in subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], text=True):
        raise SystemExit("--tuned-m4 requires an M4-family host.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).with_name("m4-native-batch.cpp")
    target_flags = {"x86_64": ["-march=haswell"] if args.tuned_m4 else [],
                    "arm64": ["-mcpu=apple-m4"] if args.tuned_m4 else []}
    for arch in ("x86_64", "arm64"):
        subprocess.run(
            ["xcrun", "clang++", "-std=c++17", "-O3", "-ffp-contract=off",
             "-Wall", "-Wextra", "-arch", arch, str(source),
             *target_flags[arch], "-o", str(output / f"probe-{arch}")], check=True
        )
    if args.benchmark:
        game_idle()
    ipc_directory = tempfile.TemporaryDirectory(prefix="ipc-", dir=output)
    ipc = Path(ipc_directory.name) / "batch"
    session_id = secrets.token_hex(8)
    env = dict(os.environ, BEDROCK_M4_TIMING="1" if args.benchmark else "0",
               BEDROCK_M4_IPC_FILE=str(ipc), BEDROCK_M4_SESSION=session_id)
    command = [str(output / "probe-x86_64"), str(output / "probe-arm64")]
    if not args.benchmark:
        command.append("--verify-only")
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, env=env, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=110)
        (output / "trials.jsonl").write_text(stdout)
        if process.returncode:
            raise SystemExit(f"Probe failed ({process.returncode}): {stderr[:2000]}")
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise SystemExit("Probe timed out; its owned process group was terminated.")
    finally:
        # Also reap a helper left behind by an early client failure. The probe
        # was started in a new session, so this group contains only our work.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
        # Usually already unlinked after the startup handshake. These random
        # names and private temporary directory belong only to this run.
        libc = ctypes.CDLL(None)
        for prefix in ("/b4r", "/b4d"):
            libc.sem_unlink((prefix + session_id).encode())
        ipc_directory.cleanup()
    rows = [json.loads(line) for line in stdout.splitlines()]
    if not rows or rows[0].get("match") is not True:
        raise SystemExit("Missing successful cross-architecture verification.")
    result = {
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "compiler": subprocess.check_output(["xcrun", "clang++", "--version"], text=True).splitlines()[0],
        "additional_target_flags": target_flags,
        "verification": rows[0],
        "scope": "Synthetic retained AABBs, one semaphore request/reply per batch. "
                 "Input extraction/marshalling, scene updates and GPU work excluded. "
                 "The game's culling cost and eligible batch sizes are unmeasured. "
                 "This is not game performance evidence.",
        "sizes": [],
    }
    for count in sorted({row["boxes"] for row in rows[1:]}):
        samples = [row for row in rows[1:] if row["boxes"] == count]
        result["sizes"].append({
            "boxes": count,
            "trials": len(samples),
            "rosetta_median_us": statistics.median(r["rosetta_ns"] for r in samples) / 1000,
            "arm64_with_ipc_median_us": statistics.median(r["arm64_with_ipc_ns"] for r in samples) / 1000,
            "arm64_kernel_median_us": statistics.median(r["arm64_kernel_ns"] for r in samples) / 1000,
            "median_paired_percent_saved": statistics.median(
                100 * (1 - r["arm64_with_ipc_ns"] / r["rosetta_ns"]) for r in samples
            ) if count else None,
            "remote_wins": sum(r["arm64_with_ipc_ns"] < r["rosetta_ns"] for r in samples),
        })
    (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
