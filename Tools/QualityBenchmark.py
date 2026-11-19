#!/usr/bin/env python3
"""Cross-platform encoder quality/speed benchmark.

Phase 1 (this PC): build representative segments (motion + still) and determine
CPU baseline VMAF targets with libx264 -preset medium -crf 28.

All temporary/output files are written under <project>/.cache/quality-benchmark.
No files outside the project folder are touched.

Usage:
  python Tools/QualityBenchmark.py prepare
  python Tools/QualityBenchmark.py baseline
  python Tools/QualityBenchmark.py detect
  python Tools/QualityBenchmark.py report
"""

import argparse
import csv
import json
import math
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".cache" / "quality-benchmark"
SEGMENTS = CACHE / "segments"
ENCODED = CACHE / "encoded"
ANALYSIS = CACHE / "analysis"
REPORTS = CACHE / "reports"
for d in (CACHE, SEGMENTS, ENCODED, ANALYSIS, REPORTS):
    d.mkdir(parents=True, exist_ok=True)

FFMPEG = os.environ.get("QB_FFMPEG", "ffmpeg")
ENCODE_FFMPEG = os.environ.get("QB_ENCODE_FFMPEG", FFMPEG)
FFPROBE = os.environ.get("QB_FFPROBE", "ffprobe")

SOURCES = {
    "BD-anime": ROOT / ".cache" / "BD-anime.m2ts",
    "BD-movie": ROOT / ".cache" / "BD-movie.m2ts",
    "DVD-anime": ROOT / ".cache" / "DVD-anime.VOB",
    "DVD-movie": ROOT / ".cache" / "DVD-movie.VOB",
}

CPU_BASELINE = {
    "encoder": "libx264",
    "preset": "medium",
    "crf": 28,
    "options": ["-c:v", "libx264", "-preset", "medium", "-crf", "28", "-pix_fmt", "yuv420p"],
}


def run(cmd, capture=True, cwd=None):
    if capture:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           errors="replace", cwd=cwd)
        return p.returncode, p.stdout
    p = subprocess.run(cmd, cwd=cwd)
    return p.returncode, ""


def probe_duration(path):
    """Return usable duration. Some VOBs report bogus durations; decode-probe them."""
    rc, out = run([FFPROBE, "-v", "error", "-select_streams", "v:0",
                   "-show_entries", "stream=duration", "-of", "csv=p=0", str(path)])
    dur = 0.0
    try:
        dur = float(out.strip().splitlines()[0])
    except Exception:
        pass
    if not math.isfinite(dur) or dur <= 0 or dur > 3600:
        # Decode with a cap and parse the last reported timestamp.
        rc, out = run([FFMPEG, "-hide_banner", "-loglevel", "info", "-i", str(path),
                       "-t", "600", "-f", "null", "NUL"])
        matches = re.findall(r"time=(\d+):(\d+):(\d+\.\d+)", out)
        if matches:
            h, m, s = matches[-1]
            dur = int(h) * 3600 + int(m) * 60 + float(s)
    return dur


def motion_score(path, start, seconds=3.0):
    rc, out = run([FFMPEG, "-hide_banner", "-loglevel", "info", "-y",
                   "-ss", f"{start:.3f}", "-t", f"{seconds:.3f}", "-i", str(path),
                   "-vf", "vmafmotion", "-an", "-f", "null", "NUL"])
    m = re.findall(r"VMAF Motion avg:\s*([\d.]+)", out)
    return float(m[-1]) if m else None


def extract_ffv1(path, start, seconds, out_path):
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
           "-ss", f"{start:.3f}", "-i", str(path), "-t", f"{seconds:.3f}",
           "-map", "0:v:0", "-an", "-c:v", "ffv1", "-level", "3", "-g", "1",
           str(out_path)]
    rc, out = run(cmd)
    if rc != 0:
        raise RuntimeError(f"FFV1 extraction failed: {out[-800:]}")


def concat_ffv1(parts, out_path):
    list_file = ANALYSIS / "concat-list.txt"
    list_file.write_text("".join(f"file '{p.as_posix()}'\n" for p in parts), encoding="utf-8")
    rc, out = run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                   "-f", "concat", "-safe", "0", "-i", str(list_file),
                   "-c", "copy", str(out_path)])
    if rc != 0:
        raise RuntimeError(f"concat failed: {out[-800:]}")


def cmd_prepare(args):
    """Create 10s (5s motion + 5s still) FFV1 segments for each source."""
    results = {}
    for name, path in SOURCES.items():
        if not path.exists():
            print(f"[SKIP] {name}: source not found ({path})")
            continue
        dur = probe_duration(path)
        print(f"[INFO] {name}: duration={dur:.1f}s")
        candidates = []
        for frac in (0.08, 0.25, 0.45, 0.65, 0.82):
            t = min(dur - 9.0, dur * frac)
            if t < 0:
                continue
            score = motion_score(path, t, 3.0)
            if score is not None:
                candidates.append((score, t))
                print(f"       t={t:7.2f}s motion={score:7.3f}")
        if len(candidates) < 2:
            print(f"[SKIP] {name}: not enough candidates")
            continue
        # Prefer clearly different motion levels: highest vs lowest.
        candidates.sort(key=lambda x: x[0])
        still_score, still_t = candidates[0]
        motion_score_v, motion_t = candidates[-1]
        if motion_score_v - still_score < 0.5:
            print(f"[WARN] {name}: motion difference small ({motion_score_v - still_score:.2f})")

        p_still = SEGMENTS / f"{name}-still.mkv"
        p_motion = SEGMENTS / f"{name}-motion.mkv"
        extract_ffv1(path, still_t, 5.0, p_still)
        extract_ffv1(path, motion_t, 5.0, p_motion)
        segment = SEGMENTS / f"{name}.mkv"
        concat_ffv1([p_still, p_motion], segment)
        results[name] = {
            "source": str(path),
            "duration": dur,
            "still": {"start": round(still_t, 3), "motion": still_score},
            "motion": {"start": round(motion_t, 3), "motion": motion_score_v},
            "segment": str(segment),
        }
        print(f"[OK] {name} -> {segment.name} (still@{still_t:.1f}s + motion@{motion_t:.1f}s)")
    (ANALYSIS / "segments.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(f"[DONE] segments.json")


def measure_vmaf(dist, ref):
    """Return dict with vmaf/ssim/psnr means for dist vs ref."""
    log_name = f"vmaf-{dist.stem}.json"
    log_path = ANALYSIS / log_name
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
           "-i", str(dist), "-i", str(ref),
           "-lavfi", f"libvmaf=log_fmt=json:log_path={log_name}",
           "-f", "null", "NUL"]
    rc, out = run(cmd, cwd=ANALYSIS)
    if rc != 0:
        raise RuntimeError(f"vmaf failed: {out[-800:]}")
    data = json.loads(log_path.read_text(encoding="utf-8"))
    vmaf = data.get("pooled_metrics", {}).get("vmaf", {}).get("mean")

    def simple_metric(filter_name, key):
        rc, out = run([FFMPEG, "-hide_banner", "-loglevel", "info", "-y",
                       "-i", str(dist), "-i", str(ref),
                       "-lavfi", filter_name, "-f", "null", "NUL"])
        m = re.findall(rf"{key}\s*([\d.]+)", out)
        return float(m[-1]) if m else None

    ssim = simple_metric("ssim", "All:")
    psnr = simple_metric("psnr", "average:")
    return {"vmaf": vmaf, "ssim": ssim, "psnr": psnr}


def cmd_baseline(args):
    """Determine CPU baseline VMAF targets (libx264 medium CRF 28)."""
    seg_info_path = ANALYSIS / "segments.json"
    if not seg_info_path.exists():
        raise SystemExit("Run 'prepare' first.")
    seg_info = json.loads(seg_info_path.read_text(encoding="utf-8"))
    results = {}
    for name, info in seg_info.items():
        seg = SEGMENTS / f"{name}.mkv"
        out = ENCODED / f"baseline-{name}.mkv"
        t0 = time.perf_counter()
        rc, log = run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                       "-i", str(seg)] + CPU_BASELINE["options"] + [str(out)])
        elapsed = time.perf_counter() - t0
        if rc != 0:
            print(f"[FAIL] {name}: {log[-500:]}")
            continue
        metrics = measure_vmaf(out, seg)
        # Use the full segment VMAF as the tuning target so every machine can
        # match the baseline without needing the encoded baseline file.
        tune_metrics = metrics
        results[name] = {
            "target_vmaf": metrics["vmaf"],
            "tune_vmaf": tune_metrics["vmaf"],
            "ssim": metrics["ssim"],
            "psnr": metrics["psnr"],
            "encode_seconds": round(elapsed, 3),
            "output": str(out),
        }
        print(f"[OK] {name}: VMAF={metrics['vmaf']:.3f} tune={tune_metrics['vmaf']:.3f} "
              f"SSIM={metrics['ssim']} PSNR={metrics['psnr']} time={elapsed:.2f}s")
    (ANALYSIS / "baseline.json").write_text(json.dumps({
        "generated_at": datetime.now().isoformat(),
        "baseline": CPU_BASELINE,
        "results": results,
    }, indent=2), encoding="utf-8")
    print("[DONE] baseline.json")


def cmd_detect(args):
    """List video encoders and test which ones actually work on this machine."""
    rc, out = run([FFMPEG, "-hide_banner", "-encoders"])
    names = []
    pattern = re.compile(r"^\s*V[.\w]+\s+([\w-]+)\s")
    for line in out.splitlines():
        m = pattern.match(line)
        if m:
            names.append(m.group(1))
    hw = [n for n in names if re.search(
        r"_(nvenc|qsv|amf|vulkan|d3d12va|mf|vaapi|nvv4l2)$", n)]
    sw = [n for n in names if n in {
        "libx264", "libx265", "libsvtav1", "libaom-av1", "librav1e",
        "libvpx-vp9", "libvpx",
    }]
    # Only hardware encoders allowed by the project policy (no MF/Vulkan/D3D12VA).
    hw = [n for n in hw if re.search(r"_(nvenc|qsv|amf|vaapi|nvv4l2)$", n)]
    available = []
    for enc in hw:
        if enc.endswith("_vaapi"):
            probe = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                     "-vaapi_device", "/dev/dri/renderD128",
                     "-f", "lavfi", "-i", "color=c=black:s=256x256:r=25:d=0.4",
                     "-frames:v", "2", "-an", "-vf", "format=nv12,hwupload",
                     "-c:v", enc, "-qp", "25", "-f", "null", "NUL"]
        else:
            probe = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                     "-f", "lavfi", "-i", "color=c=black:s=256x256:r=25:d=0.4",
                     "-frames:v", "2", "-an", "-c:v", enc, "-b:v", "2000k",
                     "-f", "null", "NUL"]
        rc, log = run(probe)
        if rc == 0:
            available.append(enc)
    report = {
        "generated_at": datetime.now().isoformat(),
        "hardware_tested": hw,
        "hardware_available": available,
        "software": sw,
        "excluded_by_policy": [n for n in names if re.search(r"_(vulkan|d3d12va|mf)$", n)],
    }
    (ANALYSIS / "encoders.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"HW available: {', '.join(available)}")
    print(f"SW: {', '.join(sw)}")
    print("[DONE] encoders.json")


def trim_clip(src, out_path, seconds=10.0):
    """Make a short copy for tuning. Segments are FFV1 with g=1 so copy is exact."""
    rc, out = run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                   "-i", str(src), "-t", f"{seconds:.3f}", "-c", "copy", str(out_path)])
    if rc != 0:
        raise RuntimeError(f"trim failed: {out[-500:]}")
    return out_path


def encoder_supported_options(encoder):
    rc, out = run([FFMPEG, "-hide_banner", "-h", f"encoder={encoder}"])
    names = set()
    for line in out.splitlines():
        m = re.match(r"^\s*-([\w]+)\s", line)
        if m:
            names.add(m.group(1))
    return names


BITRATE_EXCEPTION_ENCODERS = {"vp9_qsv", "libvpx", "h264_nvv4l2", "hevc_nvv4l2"}


def quality_range(encoder):
    """Per-encoder search range for quality values (some codecs need >35)."""
    ranges = {
        "libsvtav1": (20, 63),
        "libaom-av1": (20, 60),
        "librav1e": (20, 200),
        "libvpx-vp9": (20, 55),
        "libvpx": (10, 60),
    }
    return ranges.get(encoder, (15, 35))


def bitrate_options(encoder, mbps):
    """Bitrate-mode options for encoders whose quality mode cannot reach the target."""
    if encoder == "libvpx":
        return ["-c:v", encoder, "-cpu-used", "4",
                "-b:v", f"{mbps:.3f}M", "-pix_fmt", "yuv420p"]
    if encoder.endswith("_nvv4l2"):
        return ["-c:v", encoder, "-preset", "4", "-b:v", f"{mbps:.3f}M"]
    return ["-c:v", encoder, "-preset", "veryslow",
            "-b:v", f"{mbps:.3f}M", "-pix_fmt", "yuv420p"]


def quality_options(encoder, value):
    """Build quality-mode options. Value is the quality number to tune (15-35)."""
    v = str(int(round(value)))
    if encoder.endswith("_nvenc"):
        return ["-c:v", encoder, "-preset", "p7", "-tune", "hq",
                "-rc", "vbr", "-cq", v, "-pix_fmt", "yuv420p"]
    if encoder.endswith("_qsv"):
        if encoder in ("vp9_qsv", "mjpeg_qsv", "mpeg2_qsv"):
            return ["-c:v", encoder, "-q:v", v, "-pix_fmt", "yuv420p"]
        return ["-c:v", encoder, "-preset", "veryslow",
                "-global_quality", v, "-pix_fmt", "yuv420p"]
    if encoder.endswith("_amf"):
        return ["-c:v", encoder, "-quality", "quality", "-rc", "cqp",
                "-qp_i", v, "-qp_p", v, "-qp_b", v, "-pix_fmt", "yuv420p"]
    if encoder.endswith("_vaapi"):
        profile = ["-profile:v", "main"] if encoder.startswith("h264_") else []
        return ["-vaapi_device", "/dev/dri/renderD128",
                "-vf", "format=nv12,hwupload", "-c:v", encoder] + profile + ["-qp", v]
    if encoder in ("libx264", "libx265"):
        return ["-c:v", encoder, "-preset", "medium", "-crf", v, "-pix_fmt", "yuv420p"]
    if encoder == "libsvtav1":
        return ["-c:v", encoder, "-preset", "8", "-crf", v, "-pix_fmt", "yuv420p"]
    if encoder == "libaom-av1":
        return ["-c:v", encoder, "-cpu-used", "8", "-crf", v, "-b:v", "0",
                "-row-mt", "1", "-tiles", "2x2", "-pix_fmt", "yuv420p"]
    if encoder == "librav1e":
        return ["-c:v", encoder, "-speed", "8", "-qp", v, "-tiles", "4", "-pix_fmt", "yuv420p"]
    if encoder in ("libvpx", "libvpx-vp9"):
        return ["-c:v", encoder, "-cpu-used", "8", "-crf", v, "-b:v", "0", "-pix_fmt", "yuv420p"]
    raise ValueError(f"unknown encoder: {encoder}")


CHIP_ONLY_OPTIONS = {
    "_nvenc": ["rc-lookahead", "spatial-aq", "temporal-aq", "weighted_pred", "multipass"],
    "_qsv": ["look_ahead", "extbrc", "mbbrc", "rdo", "low_power"],
    "_amf": ["preanalysis", "preencode", "vbaq", "high_motion_quality_boost_enable", "aq_mode"],
}


def chip_only_options(encoder):
    """Return options that disable CU/shader-assisted features (dedicated circuit only)."""
    keys = None
    for suffix, opts in CHIP_ONLY_OPTIONS.items():
        if encoder.endswith(suffix):
            keys = opts
            break
    if not keys:
        return []
    supported = encoder_supported_options(encoder)
    result = []
    for name in keys:
        if name not in supported:
            continue
        if name == "multipass":
            result += ["-multipass", "disabled"]
        elif name == "low_power":
            result += ["-low_power", "1"]
        else:
            result += [f"-{name}", "0"]
    return result


def has_cu_assist(encoder):
    supported = encoder_supported_options(encoder)
    keys = []
    for suffix, opts in CHIP_ONLY_OPTIONS.items():
        if encoder.endswith(suffix):
            keys = opts
            break
    return any(k in supported for k in keys)


def encode_and_vmaf(seg, out_path, options):
    rc, log = run([ENCODE_FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                   "-i", str(seg)] + options + [str(out_path)])
    if rc != 0:
        return None, log[-500:]
    metrics = measure_vmaf(out_path, seg)
    return metrics["vmaf"], ""


def cmd_tune(args):
    """Binary-search quality value that matches CPU baseline VMAF for each encoder/material."""
    enc_path = ANALYSIS / "encoders.json"
    base_path = ANALYSIS / "baseline.json"
    seg_path = ANALYSIS / "segments.json"
    if not (enc_path.exists() and base_path.exists() and seg_path.exists()):
        raise SystemExit("Run 'detect', 'baseline' and 'prepare' first.")
    encoders = json.loads(enc_path.read_text(encoding="utf-8"))
    baseline = json.loads(base_path.read_text(encoding="utf-8"))
    segments = json.loads(seg_path.read_text(encoding="utf-8"))

    # CPU target on the 5s tuning clips. Prefer the value embedded in baseline.json
    # so remote machines do not need the (platform-specific) encoded baseline file.
    tune_targets = {}
    for name, info in segments.items():
        stored = baseline["results"].get(name, {}).get("tune_vmaf")
        if stored is not None:
            tune_targets[name] = float(stored)
            print(f"[TARGET] {name}: {float(stored):.3f} (from baseline.json)")
            continue
        full_ref = SEGMENTS / f"{name}.mkv"
        full_enc = Path(baseline["results"].get(name, {}).get("output", ""))
        if not full_enc.exists():
            continue
        ref_t = trim_clip(full_ref, SEGMENTS / f"{name}-tune-ref.mkv")
        enc_t = trim_clip(full_enc, ENCODED / f"baseline-{name}-tune.mkv")
        metrics = measure_vmaf(enc_t, ref_t)
        tune_targets[name] = metrics["vmaf"]
        print(f"[TARGET] {name}: {metrics['vmaf']:.3f}")
    if not tune_targets:
        raise SystemExit("No CPU baseline outputs available.")

    hw = encoders.get("hardware_available", [])
    # mjpeg_qsv: quality mode and bitrate mode both yield identical VMAF on this
    # platform (verified: -q:v 1..40 and -b:v 8M/20M all ~69.5) -> cannot be tuned.
    hw = [e for e in hw if e != "mjpeg_qsv"]
    sw = encoders.get("software", [])
    # Software encoders only on this PC; tune command is intended for the local machine.
    targets = hw + (sw if args.software else [])
    if args.encoders:
        only = set(x.strip() for x in args.encoders.split(",") if x.strip())
        targets = [e for e in targets if e in only]
    if args.materials:
        only_m = set(x.strip() for x in args.materials.split(",") if x.strip())
        tune_targets = {k: v for k, v in tune_targets.items() if k in only_m}
    results = {}
    for encoder in targets:
        cu = has_cu_assist(encoder)
        modes = [("normal", [])]
        if cu:
            modes.append(("chip", chip_only_options(encoder)))
        for mode_name, mode_opts in modes:
            modes_result = {}
            for name in tune_targets:
                ref_t = trim_clip(SEGMENTS / f"{name}.mkv",
                                  SEGMENTS / f"{name}-tune-ref.mkv")
                target = tune_targets[name]
                use_bitrate = encoder in BITRATE_EXCEPTION_ENCODERS
                lo, hi = (0.1, 8.0) if use_bitrate else quality_range(encoder)
                best = None
                history = []
                for iteration in range(7):
                    mid = round((lo + hi) / 2, 3) if use_bitrate else (lo + hi) // 2
                    opts = (bitrate_options(encoder, mid) if use_bitrate
                            else quality_options(encoder, mid)) + mode_opts
                    out = ENCODED / f"tune-{encoder}-{mode_name}-{name}-{mid}.mkv"
                    vmaf, err = encode_and_vmaf(ref_t, out, opts)
                    if vmaf is None:
                        history.append({"value": mid, "error": err})
                        break
                    history.append({"value": mid, "vmaf": round(vmaf, 3)})
                    diff = vmaf - target
                    if best is None or abs(diff) < abs(best[1] - target):
                        best = (mid, vmaf)
                    if abs(diff) <= 0.2:
                        break
                    # Quality numbers: higher -> lower quality -> lower VMAF.
                    # Bitrate: higher -> higher quality -> higher VMAF (inverse).
                    if use_bitrate:
                        if vmaf > target:
                            hi = round(mid - 0.05, 3)
                        else:
                            lo = round(mid + 0.05, 3)
                    else:
                        if vmaf > target:
                            lo = mid + 1
                        else:
                            hi = mid - 1
                    if lo > hi:
                        break
                modes_result[name] = {
                    "target": round(target, 3),
                    "value_unit": "Mbps" if use_bitrate else "quality",
                    "best_value": best[0] if best else None,
                    "best_vmaf": round(best[1], 3) if best else None,
                    "diff": round(best[1] - target, 3) if best else None,
                    "history": history,
                }
                print(f"[TUNE] {encoder}/{mode_name} {name}: value={best[0] if best else None} "
                      f"vmaf={best[1] if best else None} diff={modes_result[name]['diff']}")
            results[f"{encoder}:{mode_name}"] = {
                "encoder": encoder, "mode": mode_name, "cu_assist": cu,
                "chip_options": mode_opts, "materials": modes_result,
            }
    out_path = ANALYSIS / "tuning.json"
    merged = dict(results)
    if out_path.exists():
        try:
            previous = json.loads(out_path.read_text(encoding="utf-8"))
            for k, v in previous.get("results", {}).items():
                merged.setdefault(k, v)
        except Exception:
            pass
    payload = {
        "generated_at": datetime.now().isoformat(),
        "baseline_crf": 28,
        "tolerance": 0.2,
        "search_range": [15, 35],
        "targets": tune_targets,
        "results": merged,
    }
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"[DONE] {out_path}")


VARIANT_RATES = [0.3, 0.5, 0.8, 1.2, 2.0, 3.0, 5.0, 8.0]


def cmd_variants(args):
    """Encode bitrate variants on a machine that has no VMAF filter."""
    seg_path = ANALYSIS / "segments.json"
    if not seg_path.exists():
        raise SystemExit("Run 'baseline' first.")
    segments = json.loads(seg_path.read_text(encoding="utf-8"))
    encoders = [e.strip() for e in args.encoders.split(",") if e.strip()]
    for encoder in encoders:
        for name in segments:
            ref_t = trim_clip(SEGMENTS / f"{name}.mkv", SEGMENTS / f"{name}-tune-ref.mkv")
            for mbps in VARIANT_RATES:
                out = ENCODED / "variants" / encoder / f"{name}-{mbps:.3f}M.mkv"
                out.parent.mkdir(parents=True, exist_ok=True)
                opts = bitrate_options(encoder, mbps)
                rc, log = run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                               "-i", str(ref_t)] + opts + [str(out)])
                if rc != 0:
                    print(f"[FAIL] {encoder} {name} {mbps}M: {log[-200:]}")
                else:
                    print(f"[VAR] {encoder} {name} {mbps}M")
    print("[DONE] variants")


def cmd_variants_quality(args):
    """Encode quality-mode variants on a machine that has no VMAF filter."""
    seg_path = ANALYSIS / "segments.json"
    if not seg_path.exists():
        raise SystemExit("Run 'baseline' first.")
    segments = json.loads(seg_path.read_text(encoding="utf-8"))
    for encoder in [e.strip() for e in args.encoders.split(",") if e.strip()]:
        lo, hi = quality_range(encoder)
        values = list(range(lo, hi + 1, 2))
        for name in segments:
            ref_t = trim_clip(SEGMENTS / f"{name}.mkv", SEGMENTS / f"{name}-tune-ref.mkv")
            for value in values:
                out = ENCODED / "variants" / encoder / f"{name}-q{value}.mkv"
                out.parent.mkdir(parents=True, exist_ok=True)
                opts = quality_options(encoder, value)
                rc, log = run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                               "-i", str(ref_t)] + opts + [str(out)])
                print(f"[VAR] {encoder} {name} q{value} {'OK' if rc == 0 else 'FAIL'}")


def cmd_score_variants_quality(args):
    """Score quality-mode variants with VMAF on this PC."""
    tune_path = ANALYSIS / "tuning.json"
    base_path = ANALYSIS / "baseline.json"
    if not (tune_path.exists() and base_path.exists()):
        raise SystemExit("Need tuning.json and baseline.json.")
    tune = json.loads(tune_path.read_text(encoding="utf-8"))
    targets = {k: v["tune_vmaf"] for k, v in json.loads(
        base_path.read_text(encoding="utf-8"))["results"].items() if "tune_vmaf" in v}
    suffix = getattr(args, "suffix", "")
    for encoder in [e.strip() for e in args.encoders.split(",") if e.strip()]:
        materials = {}
        for name, target in targets.items():
            ref_t = SEGMENTS / f"{name}-tune-ref.mkv"
            folder = ENCODED / "variants" / f"{encoder}{suffix}"
            history = []
            for src in sorted(folder.glob(f"{name}-q*.mkv")):
                if src.stem.endswith("-tune"):
                    continue
                value = int(src.stem.split("-q")[-1])
                dst = folder / f"{src.stem}-tune.mkv"
                try:
                    trim_clip(src, dst)
                    vmaf = measure_vmaf(dst, ref_t)["vmaf"]
                except Exception:
                    continue
                history.append({"value": value, "vmaf": round(vmaf, 3)})
            if not history:
                continue
            best = min(history, key=lambda h: abs(h["vmaf"] - target))
            materials[name] = {
                "target": round(target, 3), "value_unit": "quality",
                "best_value": best["value"], "best_vmaf": best["vmaf"],
                "diff": round(best["vmaf"] - target, 3), "history": history,
            }
            print(f"[SCORE] {encoder} {name}: value={best['value']} vmaf={best['vmaf']:.3f} "
                  f"diff={materials[name]['diff']}")
        tune["results"][f"{encoder}{suffix}:normal"] = {
            "encoder": encoder + suffix, "mode": "normal", "cu_assist": False,
            "chip_options": [], "materials": materials,
        }
    tune_path.write_text(json.dumps(tune, indent=2), encoding="utf-8")
    print(f"[DONE] {tune_path}")


def cmd_score_variants(args):
    """Score variant files with VMAF on this PC and write tuning.json entries."""
    tune_path = ANALYSIS / "tuning.json"
    seg_path = ANALYSIS / "segments.json"
    base_path = ANALYSIS / "baseline.json"
    if not (tune_path.exists() and seg_path.exists() and base_path.exists()):
        raise SystemExit("Need tuning.json, segments.json and baseline.json.")
    tune = json.loads(tune_path.read_text(encoding="utf-8"))
    base = json.loads(base_path.read_text(encoding="utf-8"))
    targets = {k: v["tune_vmaf"] for k, v in base["results"].items() if "tune_vmaf" in v}
    encoders = [e.strip() for e in args.encoders.split(",") if e.strip()]
    for encoder in encoders:
        materials = {}
        for name, target in targets.items():
            ref_t = SEGMENTS / f"{name}-tune-ref.mkv"
            history = []
            for mbps in VARIANT_RATES:
                src = ENCODED / "variants" / encoder / f"{name}-{mbps:.3f}M.mkv"
                if not src.exists() or src.stat().st_size < 1024:
                    continue
                dst = ENCODED / "variants" / encoder / f"{name}-{mbps:.3f}M-tune.mkv"
                try:
                    trim_clip(src, dst)
                    vmaf = measure_vmaf(dst, ref_t)["vmaf"]
                except Exception:
                    continue
                history.append({"value": mbps, "vmaf": round(vmaf, 3)})
            if not history:
                continue
            best = min(history, key=lambda h: abs(h["vmaf"] - target))
            materials[name] = {
                "target": round(target, 3), "value_unit": "Mbps",
                "best_value": best["value"], "best_vmaf": best["vmaf"],
                "diff": round(best["vmaf"] - target, 3), "history": history,
            }
            print(f"[SCORE] {encoder} {name}: value={best['value']} vmaf={best['vmaf']:.3f} "
                  f"diff={materials[name]['diff']}")
        tune["results"][f"{encoder}:normal"] = {
            "encoder": encoder, "mode": "normal", "cu_assist": False,
            "chip_options": [], "materials": materials,
        }
    tune_path.write_text(json.dumps(tune, indent=2), encoding="utf-8")
    print(f"[DONE] {tune_path}")


def cmd_final(args):
    """Encode full 10s segments with the proposed common values and measure speed/quality."""
    tune_path = ANALYSIS / "tuning.json"
    seg_path = ANALYSIS / "segments.json"
    if not (tune_path.exists() and seg_path.exists()):
        raise SystemExit("Run 'tune' first.")
    tune = json.loads(tune_path.read_text(encoding="utf-8"))
    segments = json.loads(seg_path.read_text(encoding="utf-8"))
    results = {}
    for key, entry in tune.get("results", {}).items():
        if args.encoders:
            only = set(x.strip() for x in args.encoders.split(",") if x.strip())
            if entry["encoder"] not in only:
                continue
        # Common value = value with the smallest worst-case VMAF deviation.
        candidates = {}
        for material, r in entry.get("materials", {}).items():
            for h in r.get("history", []):
                if "vmaf" not in h:
                    continue
                d = abs(h["vmaf"] - r["target"])
                candidates[h["value"]] = max(candidates.get(h["value"], 0.0), d)
        if not candidates:
            continue
        value = min(candidates, key=candidates.get)
        unit = next(iter(entry["materials"].values())).get("value_unit", "quality")
        mode_opts = entry.get("chip_options", [])
        encoder = entry["encoder"]
        material_results = {}
        for name in segments:
            seg = SEGMENTS / f"{name}.mkv"
            opts = (bitrate_options(encoder, value) if unit == "Mbps"
                    else quality_options(encoder, value)) + mode_opts
            out = ENCODED / f"final-{encoder}-{entry['mode']}-{name}.mkv"
            t0 = time.perf_counter()
            rc, log = run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                           "-i", str(seg)] + opts + [str(out)])
            elapsed = time.perf_counter() - t0
            if rc != 0:
                material_results[name] = {"error": log[-300:]}
                continue
            metrics = measure_vmaf(out, seg)
            probe = run([FFPROBE, "-v", "error", "-select_streams", "v:0",
                         "-count_frames", "-show_entries", "stream=nb_read_frames",
                         "-of", "csv=p=0", str(out)])
            try:
                frames = int(probe[1].strip().splitlines()[0])
            except Exception:
                frames = 0
            material_results[name] = {
                "value": value, "unit": unit,
                "vmaf": metrics["vmaf"], "ssim": metrics["ssim"], "psnr": metrics["psnr"],
                "encode_seconds": round(elapsed, 3),
                "fps": round(frames / elapsed, 2) if elapsed > 0 else None,
            }
            print(f"[FINAL] {key} {name}: value={value} vmaf={metrics['vmaf']:.3f} "
                  f"time={elapsed:.2f}s fps={material_results[name]['fps']}")
        results[key] = {
            "encoder": encoder, "mode": entry["mode"],
            "common_value": value, "unit": unit,
            "worst_deviation": round(candidates[value], 3),
            "materials": material_results,
        }
    out_path = ANALYSIS / "final.json"
    out_path.write_text(json.dumps({
        "generated_at": datetime.now().isoformat(), "results": results,
    }, indent=2), encoding="utf-8")
    print(f"[DONE] {out_path}")


def cmd_report(args):
    base_path = ANALYSIS / "baseline.json"
    if not base_path.exists():
        raise SystemExit("Run 'baseline' first.")
    base = json.loads(base_path.read_text(encoding="utf-8"))
    lines = ["# 品質ベンチマーク レポート", "", "## CPU 基準点", "",
             "| 素材 | 目標VMAF | SSIM | PSNR | エンコード秒 |", "|---|---:|---:|---:|---:|"]
    for name, r in base["results"].items():
        lines.append(f"| {name} | {r['target_vmaf']:.2f} | {r['ssim']:.4f} | "
                     f"{r['psnr']:.2f} | {r['encode_seconds']:.2f} |")
    lines += ["", f"基準: `{' '.join(base['baseline']['options'])}`", ""]

    tune_path = ANALYSIS / "tuning.json"
    if tune_path.exists():
        tune = json.loads(tune_path.read_text(encoding="utf-8"))
        lines += ["## 品質数値のチューニング結果", "",
                  "目標: CPU基準(CRF 28)と同一VMAF（±0.2）。範囲外のコーデックは個別範囲／例外ビットレートを使用", "",
                  "| エンコーダー | モード | 素材 | 最適値 | 単位 | VMAF | 差分 |",
                  "|---|---|---|---:|---|---:|---:|"]
        common = {}
        for key, entry in tune.get("results", {}).items():
            for material, r in entry.get("materials", {}).items():
                v = r.get("best_value")
                vm = r.get("best_vmaf")
                diff = r.get("diff")
                unit = r.get("value_unit", "quality")
                lines.append(f"| {entry['encoder']} | {entry['mode']} | {material} | "
                             f"{v if v is not None else '-'} | {unit} | "
                             f"{vm if vm is not None else '-'} | "
                             f"{diff if diff is not None else '-'} |")
                # Propose a common value minimizing the worst deviation across materials.
                candidates = {}
                for h in r.get("history", []):
                    if "vmaf" not in h:
                        continue
                    d = abs(h["vmaf"] - r["target"])
                    prev = candidates.get(h["value"])
                    if prev is None or d < prev:
                        candidates[h["value"]] = d
                for value, worst in candidates.items():
                    acc = common.setdefault(key, {})
                    old = acc.get(value, 0.0)
                    acc[value] = max(old, worst)
            if key in common:
                best_value = min(common[key], key=common[key].get)
                lines.append(f"| **{entry['encoder']}** | **{entry['mode']}** | "
                             f"**共通値提案** | **{best_value}** | - | - | "
                             f"**最大偏差 {common[key][best_value]:.2f}** |")
        lines.append("")

        final_path = ANALYSIS / "final.json"
        if final_path.exists():
            final = json.loads(final_path.read_text(encoding="utf-8"))
            lines += ["## 本番測定 (10秒)", "",
                      "| エンコーダー | モード | 共通値 | 素材 | VMAF | 速度(fps) | 秒 |",
                      "|---|---|---:|---|---:|---:|---:|"]
            for key, r in final.get("results", {}).items():
                for material, m in r.get("materials", {}).items():
                    if "error" in m:
                        continue
                    lines.append(f"| {r['encoder']} | {r['mode']} | {r['common_value']} | "
                                 f"{material} | {m['vmaf']:.2f} | {m['fps']} | "
                                 f"{m['encode_seconds']:.2f} |")
            lines.append("")

    out = REPORTS / "baseline-report.md"
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"[DONE] {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare")
    sub.add_parser("baseline")
    sub.add_parser("detect")
    tune_parser = sub.add_parser("tune")
    tune_parser.add_argument("--software", action="store_true",
                             help="also tune software encoders (local PC only)")
    tune_parser.add_argument("--encoders", default="",
                             help="comma-separated encoder filter")
    tune_parser.add_argument("--materials", default="",
                             help="comma-separated material filter")
    variants_parser = sub.add_parser("variants")
    variants_parser.add_argument("--encoders", required=True, help="comma-separated encoder filter")
    vq_parser = sub.add_parser("variants-quality")
    vq_parser.add_argument("--encoders", required=True, help="comma-separated encoder filter")
    score_parser = sub.add_parser("score-variants")
    score_parser.add_argument("--encoders", required=True, help="comma-separated encoder filter")
    sq_parser = sub.add_parser("score-variants-quality")
    sq_parser.add_argument("--encoders", required=True, help="comma-separated encoder filter")
    sq_parser.add_argument("--suffix", default="", help="variant folder suffix (e.g. -8750h)")
    final_parser = sub.add_parser("final")
    final_parser.add_argument("--encoders", default="", help="comma-separated encoder filter")
    sub.add_parser("report")
    args = parser.parse_args()
    {"prepare": cmd_prepare, "baseline": cmd_baseline,
     "detect": cmd_detect, "tune": cmd_tune, "variants": cmd_variants,
     "variants-quality": cmd_variants_quality,
     "score-variants": cmd_score_variants,
     "score-variants-quality": cmd_score_variants_quality,
     "final": cmd_final,
     "report": cmd_report}[args.command](args)


if __name__ == "__main__":
    main()
