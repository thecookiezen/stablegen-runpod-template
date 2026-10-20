#!/usr/bin/env python3
"""Headless driver for StableGen's installer.py.

StableGen's installer.py is an interactive menu script (it calls input()), so
it cannot run unattended inside a RunPod boot. This driver imports it as a
module and replays its per-item installation logic for a fixed set of package
tags, keeping all of its hard-won behavior: pinned node handling, post-clone
compat patches, comfy-env patch/reinstall dance, CUDA 12.4 install retry,
flex_gemm triton patch, and resumable downloads.

One addition over installer.py: every comfy-env install is pinned (derived
from the pinned ComfyUI-TRELLIS2's requirements.txt, override with
STABLEGEN_COMFY_ENV_PIN). Unversioned installs resolve to comfy-env 0.4.x,
whose stricter root-config schema rejects the node's comfy-env-root.toml
([cuda]/[node_reqs]) -- breaking both install.py and ComfyUI's import.

Run it with the ComfyUI venv interpreter so sys.executable (installer.py's
fallback for find_comfyui_python) is the interpreter that runs install.py:

    /workspace/runpod-slim/ComfyUI/.venv-cu128/bin/python \\
        /opt/stablegen-template/stablegen_install.py /workspace/runpod-slim/ComfyUI

Environment:
    STABLEGEN_REPO   where installer.py lives (default /opt/stablegen)
    STABLEGEN_TAGS   space-separated package tags to install (see below)

Default tag set and approximate download volume onto the network volume:
    core               IPAdapter Plus node + SDXL IPAdapter/CLIP vision models
    preset_essentials  ControlNet depth SDXL
    extended_optional  extra LoRAs + ControlNets
    pbr_marigold       ComfyUI-Marigold node
    pbr_stabledelight  ComfyUI_StableDelight_ll node + yoso-delight model
    checkpoint_realvis RealVisXL V5.0 fp16 checkpoint
    qwen_core          ComfyUI-GGUF node + Qwen Image Edit GGUF/VAE/encoder
    trellis2           ComfyUI-TRELLIS2 node + CUDA env builds (GPU required)
"""

import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

STABLEGEN_REPO = Path(os.environ.get("STABLEGEN_REPO", "/opt/stablegen"))

DEFAULT_TAGS = (
    "core preset_essentials extended_optional "
    "pbr_marigold pbr_stabledelight "
    "checkpoint_realvis qwen_core trellis2"
)

# comfy-env must stay on the 0.3.x config schema this stack is built for.
# The pinned ComfyUI-TRELLIS2 commit ships a comfy-env-root.toml with [cuda]
# and [node_reqs] sections and pins comfy-env==0.3.89 in its requirements.txt;
# comfy-env >= 0.4.25 hard-rejects those sections ("comfy-env-root.toml
# carries [node_packs] and [types] only"). An unversioned `pip install
# comfy-env` resolves to the latest 0.4.x, which makes the node's install.py
# fail AND makes ComfyUI's import of the node crash at startup. Default to
# what the pinned node itself declares; STABLEGEN_COMFY_ENV_PIN overrides.
COMFY_ENV_FALLBACK_PIN = "comfy-env==0.3.89"


def _comfy_env_pin(comfyui_path: Path) -> str:
    """Derive the comfy-env pin from the pinned TRELLIS2's requirements.txt."""
    override = os.environ.get("STABLEGEN_COMFY_ENV_PIN", "").strip()
    if override:
        return override
    req = comfyui_path / "custom_nodes" / "ComfyUI-TRELLIS2" / "requirements.txt"
    try:
        for line in req.read_text(encoding="utf-8").splitlines():
            spec = line.strip()
            if spec.lower().replace("_", "-").startswith("comfy-env") and any(
                c in spec for c in "=<>~!"
            ):
                return spec
    except OSError:
        pass
    return COMFY_ENV_FALLBACK_PIN


def _pin_version(spec: str):
    """The exact version of an `==` pin, else None (range spec / bare name)."""
    m = re.search(r"==\s*([0-9][^\s;]*)", spec)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# install.py heartbeat
#
# install.py steps nest subprocesses (comfy-env -> pixi -> rattler/uv) that
# can run SILENT for 10-30+ minutes on first boot: comfy-env forces
# PIXI_NO_PROGRESS=true, which suppresses every solve/download/link progress
# line. From the outside a healthy build is indistinguishable from a wedged
# network read. The wrapper below (installed onto installer.py's subprocess
# module, so it also covers installer.py's internal retry paths) prints a
# liveness line every STABLEGEN_HEARTBEAT_SECS (default 60) showing the
# caches/env dirs growing, and can kill the whole process group after
# STABLEGEN_INSTALL_TIMEOUT seconds (default 0 = wait forever; the component
# is then marked failed and the boot continues, retried on next boot).
# ---------------------------------------------------------------------------
HEARTBEAT_SECS = max(5, int(os.environ.get("STABLEGEN_HEARTBEAT_SECS", "60")))
INSTALL_TIMEOUT = int(os.environ.get("STABLEGEN_INSTALL_TIMEOUT", "0"))


def _du_mb(path: str) -> str:
    try:
        r = subprocess.run(["du", "-sm", path], capture_output=True, text=True, timeout=180)
        if r.returncode == 0 and r.stdout.split():
            return f"{r.stdout.split()[0]}MB"
    except Exception:
        pass
    return "?"


def _make_install_script_heartbeat(installer):
    """Wrap subprocess.run inside installer.py so install.py runs heartbeat."""
    orig_run = installer.subprocess.run  # the stdlib subprocess module

    def _du_line() -> str:
        ce = os.environ.get("COMFY_ENV_ROOT", "/workspace/.ce")
        pixi = os.environ.get("PIXI_CACHE_DIR", str(Path.home() / ".pixi"))
        uv = os.environ.get("UV_CACHE_DIR", str(Path.home() / ".cache" / "uv"))
        return (f"pixi-cache={_du_mb(pixi)} uv-cache={_du_mb(uv)} "
                f"envs={_du_mb(ce)}")

    def _run(args, **kwargs):
        cmd = list(args) if isinstance(args, (list, tuple)) else [args]
        is_install_script = any(
            isinstance(a, (str, os.PathLike)) and str(a).endswith("install.py")
            for a in cmd
        )
        if not is_install_script:
            return orig_run(args, **kwargs)

        check = kwargs.pop("check", False)
        cwd = kwargs.pop("cwd", None)
        print(f"  [watchdog] heartbeat every {HEARTBEAT_SECS}s "
              f"(pixi/rattler/uv are silent by design; sizes growing = working)",
              flush=True)
        # Own process group so a timeout kill takes out the nested
        # install.py -> comfy-env -> pixi tree, not just the top child.
        proc = subprocess.Popen(cmd, cwd=cwd, start_new_session=True)
        start = time.monotonic()
        while True:
            try:
                proc.wait(timeout=HEARTBEAT_SECS)
                break
            except subprocess.TimeoutExpired:
                elapsed = int(time.monotonic() - start)
                print(f"  [install.py +{elapsed // 60}m{elapsed % 60:02d}s] "
                      f"{_du_line()}", flush=True)
                if INSTALL_TIMEOUT and elapsed >= INSTALL_TIMEOUT:
                    print(f"  TIMEOUT after {elapsed}s "
                          f"(STABLEGEN_INSTALL_TIMEOUT) -> killing install.py",
                          flush=True)
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except Exception:
                        proc.kill()
                    proc.wait()
                    break
        if check and proc.returncode != 0:
            raise subprocess.CalledProcessError(proc.returncode, cmd)
        return subprocess.CompletedProcess(cmd, proc.returncode)

    installer.subprocess.run = _run


def _installed_comfy_env_version():
    try:
        result = subprocess.run(
            [sys.executable, "-c",
             'import importlib.metadata as m; print(m.version("comfy-env"))'],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            return result.stdout.strip() or None
    except Exception:
        pass
    return None


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    if len(sys.argv) < 2:
        die("usage: stablegen_install.py <ComfyUI directory>")

    comfyui_path = Path(sys.argv[1]).resolve()
    if not comfyui_path.is_dir():
        die(f"ComfyUI path '{comfyui_path}' not found.")
    if not (comfyui_path / "models").is_dir() or not (comfyui_path / "custom_nodes").is_dir():
        die(f"'{comfyui_path}' does not look like a ComfyUI directory "
            f"(missing 'models' or 'custom_nodes').")

    installer_py = STABLEGEN_REPO / "installer.py"
    if not installer_py.is_file():
        die(f"installer.py not found at {installer_py} (set STABLEGEN_REPO).")

    sys.path.insert(0, str(STABLEGEN_REPO))
    import installer  # noqa: E402  (path set above on purpose)

    # install.py runs (comfy-env -> pixi) are silent for long stretches; make
    # them visibly alive (and optionally bounded) before any of them start.
    _make_install_script_heartbeat(installer)

    tags = [t for t in os.environ.get("STABLEGEN_TAGS", DEFAULT_TAGS).split() if t]
    item_ids = sorted(installer.get_unique_item_ids_for_tags(tags))
    pin = _comfy_env_pin(comfyui_path)

    print("=" * 60)
    print("StableGen headless install")
    print(f"  ComfyUI:    {comfyui_path}")
    print(f"  Python:     {sys.executable}")
    print(f"  installer:  {installer_py}")
    print(f"  tags:       {' '.join(tags)}")
    unknown = [t for t in tags if not any(
        t in d.get("packages", []) for d in installer.DEPENDENCIES.values())]
    if unknown:
        die(f"unknown tag(s): {' '.join(unknown)}")
    print(f"  components: {len(item_ids)}")
    print(f"  comfy-env:  {pin}")
    print("=" * 60)

    # Pre-flight, same idea as installer.main() but with the comfy-env version
    # FORCED to the pin first: patches are applied to whatever is installed,
    # and a wrong version (a leftover 0.4.x from an older boot, or the
    # unversioned latest a previous run pulled) both breaks the TRELLIS2
    # install.py and crashes ComfyUI's import of the node later.
    # Route every comfy-env install through the pin: the DEPENDENCIES entries,
    # installer.py's internal failure-retry, and our own reinstall below all
    # call installer.install_pip_packages with a bare "comfy-env" spec.
    _orig_install_pip_packages = installer.install_pip_packages

    def _install_pip_packages_pinned(pip_packages, comfyui_path_, force_reinstall=False):
        pinned = [pin if p.strip().lower() == "comfy-env" else p for p in pip_packages]
        return _orig_install_pip_packages(pinned, comfyui_path_, force_reinstall)

    installer.install_pip_packages = _install_pip_packages_pinned

    want_version = _pin_version(pin)
    try:
        importable = subprocess.run(
            [sys.executable, "-c", "import comfy_env"],
            capture_output=True, text=True,
        ).returncode == 0
        if not importable or (want_version is not None
                              and _installed_comfy_env_version() != want_version):
            print(f"Ensuring {pin} (config-schema compatible with the pinned nodes)...")
            _orig_install_pip_packages([pin], comfyui_path)
        if subprocess.run([sys.executable, "-c", "import comfy_env"],
                          capture_output=True).returncode == 0:
            print("Detected existing comfy-env; ensuring patches are applied...")
            installer._apply_all_comfy_env_patches(comfyui_path)
    except Exception as e:  # pragma: no cover - defensive, matches installer.py
        print(f"WARNING: could not check/patch existing comfy-env: {e}")

    failures = []

    # This block mirrors the per-item loop of installer.main() (the part after
    # the interactive confirmation), including ordering of pip installs,
    # patches, install.py execution and the comfy-env reinstall afterwards.
    for item_id in item_ids:
        d = installer.DEPENDENCIES.get(item_id)
        if d is None:
            continue
        print()
        print(f"--- Processing: {d['name']} ---")

        try:
            if d["type"] == "node":
                target_full_path = comfyui_path / d["target_dir_relative"] / d["repo_name"]
                installer.clone_git_repo(d, comfyui_path)
                if d.get("pip_packages"):
                    installer.install_pip_packages(d["pip_packages"], comfyui_path)
                    # comfy-env patches must exist BEFORE install.py runs
                    if any("comfy-env" in p for p in d["pip_packages"]):
                        installer._apply_all_comfy_env_patches(comfyui_path)
                if d.get("post_clone_patches"):
                    installer.apply_post_clone_patches(d, comfyui_path)
                if d.get("run_install_script"):
                    installer.run_node_install_script(d, comfyui_path)
                    installer._patch_flex_gemm_autotuner(target_full_path)
                # install.py may have replaced comfy-env via its
                # requirements.txt; force ours back and re-patch.
                if d.get("pip_packages") and any("comfy-env" in p for p in d["pip_packages"]):
                    print(f"  Re-installing {pin} (overriding node requirements.txt)...")
                    installer.install_pip_packages(["comfy-env"], comfyui_path, force_reinstall=True)
                    installer._apply_all_comfy_env_patches(comfyui_path)
            elif d["type"] == "model":
                installer.download_file(d, comfyui_path)
            elif d["type"] == "hf_model":
                installer.download_hf_model(d, comfyui_path)
            else:
                print(f"  WARNING: unknown dependency type '{d['type']}', skipped.")
        except SystemExit as e:
            # installer.py calls sys.exit(1) on some failures; surface it but
            # keep installing the remaining components.
            print(f"  FAILED (exit {e.code}) - continuing with remaining components")
            failures.append(d["name"])
        except Exception as e:
            print(f"  FAILED: {e} - continuing with remaining components")
            failures.append(d["name"])

    # Final guard: whatever the nodes' install scripts did to comfy-env along
    # the way, the version ComfyUI imports at startup must accept the packs'
    # root configs, or ComfyUI-TRELLIS2 fails to import at boot.
    if want_version is not None and _installed_comfy_env_version() != want_version:
        print(f"Restoring {pin} after node installs...")
        installer.install_pip_packages(["comfy-env"], comfyui_path, force_reinstall=True)
        installer._apply_all_comfy_env_patches(comfyui_path)

    print()
    print("=" * 60)
    if failures:
        print("Completed with failures (re-run this script to retry):")
        for name in failures:
            print(f"  - {name}")
        print("=" * 60)
        return 1
    print("All components processed successfully.")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
