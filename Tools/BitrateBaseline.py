#!/usr/bin/env python3
"""Compute VMAF baseline for constant (CBR) and variable (VBR) bitrate modes."""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "quality-benchmark"
SEGMENTS = CACHE / "segments"
ENCODED = CACHE / "encoded" / "bitrate"
ANALYSIS = CACHE / "analysis"
MATERIALS = ["BD-anime", "BD-movie", "DVD-anime", "DVD-movie"]

FFMPEG = os.environ.get("QB_FFMPEG", "ffmpeg")


def run(cmd, cwd=None):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, errors="replace", cwd=cwd)
    return p.returncode, p.stdout


def bitrate_kbps(path):
    probe = str(Path(FFMPEG).with_name("ffprobe"))
    rc, out = run([probe, "-v", "error", "-show_entries", "format=bit_rate,duration",
                   "-of", "json", str(path)])
    if rc != 0:
        return None
    try:
        d = json.loads(out)["format"]
        return round(float(d["bit_rate"]) / 1000.0, 1)
    except Exception:
        return None


def vmaf(dist, ref):
    name = f"vmaf-bitrate-{dist.stem}.json"
    rc, out = run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                   "-i", str(dist), "-i", str(ref),
                   "-lavfi", f"libvmaf=log_fmt=json:log_path={name}",
                   "-f", "null", "NUL"], cwd=ANALYSIS)
    if rc != 0:
        return None, out[-300:]
    try:
        d = json.loads((ANALYSIS / name).read_text(encoding="utf-8"))
        return d["pooled_metrics"]["vmaf"]["mean"], ""
    except Exception as e:
        return None, str(e)


def encode(ref, out, target_kbps, mode):
    if mode == "cbr":
        params = ["-x264-params", f"nal-hrd=cbr:vbv-maxrate={target_kbps}:vbv-bufsize={target_kbps * 2}"]
    else:
        params = []
    rc, log = run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                   "-i", str(ref), "-c:v", "libx264", "-preset", "medium",
                   "-b:v", f"{target_kbps}k", "-maxrate", f"{target_kbps}k",
                   "-bufsize", f"{target_kbps * 2}k"] + params +
                  ["-an", str(out)])
    return rc, log


def find_match(ref, target_vmaf, mode, initial):
    lo, hi = max(100, int(initial * 0.3)), int(initial * 3.0)
    best = None
    for _ in range(7):
        mid = (lo + hi) // 2
        out = ENCODED / f"{mode}-{ref.stem}-{mid}.mkv"
        rc, log = encode(ref, out, mid, mode)
        if rc != 0:
            return None, f"encode failed: {log[-200:]}"
        score, err = vmaf(out, ref)
        if score is None:
            return None, err
        if best is None or abs(score - target_vmaf) < abs(best[1] - target_vmaf):
            best = (mid, score, bitrate_kbps(out))
        if abs(score - target_vmaf) <= 0.3:
            return best, ""
        if score > target_vmaf:
            hi = mid - 1
        else:
            lo = mid + 1
        if lo > hi:
            break
    return best, ""


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", choices=["cbr", "vbr", "both"], default="both")
    args = ap.parse_args()
    ENCODED.mkdir(parents=True, exist_ok=True)
    ANALYSIS.mkdir(parents=True, exist_ok=True)

    baseline_path = ANALYSIS / "baseline.json"
    if not baseline_path.exists():
        raise SystemExit("baseline.json not found")
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))

    results = {}
    for name in MATERIALS:
        ref = SEGMENTS / f"{name}.mkv"
        if not ref.exists():
            continue
        target = baseline["results"][name]["target_vmaf"]
        crf_file = ENCODED.parent / f"baseline-{name}.mkv"
        initial = bitrate_kbps(crf_file) or 4000
        results[name] = {"target_vmaf": round(target, 3),
                         "crf28_kbps": initial, "modes": {}}
        for mode in (["cbr", "vbr"] if args.mode == "both" else [args.mode]):
            best, err = find_match(ref, target, mode, initial)
            if best:
                results[name]["modes"][mode] = {
                    "target_kbps": best[0], "actual_kbps": best[2],
                    "vmaf": round(best[1], 3),
                    "diff": round(best[1] - target, 3),
                }
                print(f"[BITRATE] {name} {mode}: {best[0]}k -> VMAF {best[1]:.2f} "
                      f"(diff {best[1] - target:+.2f}, actual {best[2]}k)")
            else:
                results[name]["modes"][mode] = {"error": err}
                print(f"[BITRATE] {name} {mode}: FAILED {err}")
    out = ANALYSIS / "bitrate-baseline.json"
    out.write_text(json.dumps({"generated_at": datetime.now().isoformat(),
                               "segment_duration": 10,
                               "results": results}, indent=2), encoding="utf-8")
    print(f"[DONE] {out}")


if __name__ == "__main__":
    main()
