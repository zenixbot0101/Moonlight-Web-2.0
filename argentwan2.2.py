#!/usr/bin/env python3
"""
wan22_animate_host_test.py - Cai dat Wan2.2-Animate-14B tren Ubuntu,
kiem tra CUDA / thu vien / checkpoint, sau do chay giao dien Gradio.

Chay:
    python3 wan22_animate_host_test.py --check-only
    python3 wan22_animate_host_test.py                 # cai A-Z + chay web UI
    python3 wan22_animate_host_test.py --no-tunnel     # chi truy cap local
    python3 wan22_animate_host_test.py --install-only  # cai va kiem tra, chua mo UI
    python3 wan22_animate_host_test.py --skip-install  # kiem tra bo cai dat cu + chay UI

Model Animate-14B can tai khoang 55-60 GB; nen co it nhat 150 GB dung luong
trong va GPU NVIDIA dung luong VRAM lon (khuyen nghi 80-96 GB).

Khuyen nghi chay trong tmux/screen:  tmux new -s wan
"""
import argparse
import getpass
import os
import re
import secrets
import shutil
import subprocess
import sys
import textwrap
import threading
import time
from pathlib import Path

# ----------------------------------------------------------------------------
# Cau hinh
# ----------------------------------------------------------------------------
BASE = Path(os.environ.get("WAN_BASE", Path.home() / "wan-animate"))
REPO = BASE / "Wan2.2"
CKPT = BASE / "Wan2.2-Animate-14B"
VENV = BASE / ".venv"
WORK = BASE / "jobs"
APP = BASE / "app.py"
CRED = BASE / "credentials.txt"
PY = VENV / "bin" / "python"
PORT_DEFAULT = 7860

# Chay trong notebook (marimo/Jupyter)? Khi do sys.argv la cua notebook, khong dung cho argparse.
IN_NOTEBOOK = any(m in sys.modules for m in ("marimo", "ipykernel", "IPython"))
# Tham so dung khi chay trong notebook - sua tuy y (vd bo --skip-install de cai lai tu dau).
NOTEBOOK_ARGS = ["--skip-install", "--reset-credentials"]

REPO_URL = "https://github.com/Wan-Video/Wan2.2.git"
HF_REPO = "Wan-AI/Wan2.2-Animate-14B"
# RTX PRO 6000 (Blackwell, sm_120) can PyTorch build CUDA 12.8+
TORCH_SPEC = ["torch==2.7.1", "torchvision==0.22.1", "torchaudio==2.7.1"]
TORCH_INDEX = "https://download.pytorch.org/whl/cu128"
MIN_PYTHON = (3, 10)
MIN_FREE_GB = 100
RECOMMENDED_FREE_GB = 150

MODEL_FILES = [
    "diffusion_pytorch_model-00001-of-00004.safetensors",
    "diffusion_pytorch_model-00002-of-00004.safetensors",
    "diffusion_pytorch_model-00003-of-00004.safetensors",
    "diffusion_pytorch_model-00004-of-00004.safetensors",
    "diffusion_pytorch_model.safetensors.index.json",
    "Wan2.1_VAE.pth",
    "models_t5_umt5-xxl-enc-bf16.pth",
    "models_clip_open-clip-xlm-roberta-large-vit-huge-14.pth",
    "relighting_lora.ckpt",
    "process_checkpoint/det/yolov10m.onnx",
    "process_checkpoint/sam2/sam2_hiera_large.pt",
]
MODEL_DIRS = ["process_checkpoint/pose2d/vitpose_h_wholebody.onnx"]


def log(msg):
    print(f"\n\033[1;36m[wan]\033[0m {msg}", flush=True)


def run(cmd, cwd=None, check=True, env=None, shell=False):
    printable = cmd if isinstance(cmd, str) else " ".join(str(c) for c in cmd)
    print(f"\033[90m$ {printable}\033[0m", flush=True)
    return subprocess.run(cmd, cwd=cwd, check=check, env=env, shell=shell)


def sudo():
    return [] if os.geteuid() == 0 else ["sudo"]


# ----------------------------------------------------------------------------
# 1. Kiem tra he thong
# ----------------------------------------------------------------------------
def check_system():
    log("Kiem tra he thong")
    if not sys.platform.startswith("linux"):
        sys.exit("Script nay chi ho tro Linux/Ubuntu.")
    if not shutil.which("apt-get"):
        sys.exit("Khong tim thay apt-get. Hay dung host Ubuntu/Debian.")
    if not shutil.which("nvidia-smi"):
        sys.exit(
            "Khong thay nvidia-smi. Hay cai NVIDIA driver va xac nhan nvidia-smi hoat dong; "
            "RTX PRO 6000 Blackwell can driver tuong thich CUDA 12.8 (thuong >= 570)."
        )
    run(["nvidia-smi"])
    gpu = subprocess.run(
        ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits"],
        capture_output=True,
        text=True,
        check=False,
    )
    if gpu.returncode == 0:
        for row in gpu.stdout.strip().splitlines():
            parts = [part.strip() for part in row.split(",", 1)]
            if len(parts) == 2:
                try:
                    vram_gb = float(parts[1]) / 1024
                    print(f"GPU: {parts[0]} - {vram_gb:.1f} GB VRAM")
                    if vram_gb < 80:
                        print("CANH BAO: Animate-14B can GPU VRAM lon; host duoi 80 GB co the OOM.")
                except ValueError:
                    print(f"GPU: {row}")

    disk_path = BASE.parent if BASE.parent.exists() else Path.home()
    free_gb = shutil.disk_usage(disk_path).free / 1e9
    print(f"Dung luong trong tai {disk_path}: {free_gb:.0f} GB")
    if free_gb > 1e7:
        print("CANH BAO: filesystem bao dung luong ao/khong xac dinh; bo qua kiem tra dung luong. "
              "Hay tu kiem tra bang `df -h ~` (can >= 100 GB).")
    elif free_gb < MIN_FREE_GB:
        sys.exit(
            f"Khong du dung luong de cai model an toan: con {free_gb:.0f} GB, "
            f"toi thieu khuyen nghi {MIN_FREE_GB} GB."
        )
    if free_gb <= 1e7 and free_gb < RECOMMENDED_FREE_GB:
        print(f"CANH BAO: nen co >= {RECOMMENDED_FREE_GB} GB trong cho model, cache va pip.")


# ----------------------------------------------------------------------------
# 2. Goi he thong
# ----------------------------------------------------------------------------
def install_apt():
    log("Cai goi he thong (apt)")
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    run(sudo() + ["apt-get", "update"], env=env)
    run(
        sudo()
        + ["apt-get", "install", "-y", "git", "git-lfs", "ffmpeg", "curl", "ca-certificates",
           "build-essential", "python3", "python3-venv", "python3-pip", "openssh-client",
           "libgl1", "libglib2.0-0", "tmux"],
        env=env,
    )
    run(["git", "lfs", "install"], check=False)


# ----------------------------------------------------------------------------
# 3. Python venv (uu tien Python 3.11 qua uv, du phong python3 he thong)
# ----------------------------------------------------------------------------
def make_venv():
    if PY.exists():
        version = subprocess.check_output(
            [str(PY), "-c", "import sys;print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
            text=True,
        ).strip()
        major, minor = (int(part) for part in version.split(".")[:2])
        if (major, minor) < MIN_PYTHON:
            sys.exit(
                f"Virtualenv hien tai dung Python {version}; can Python >= "
                f"{MIN_PYTHON[0]}.{MIN_PYTHON[1]}. Hay backup/doi WAN_BASE roi chay lai."
            )
        log(f"venv da ton tai, Python {version}; bo qua tao moi")
        return
    log("Tao virtualenv")
    BASE.mkdir(parents=True, exist_ok=True)
    uv = shutil.which("uv") or str(Path.home() / ".local/bin/uv")
    if not Path(uv).exists():
        run("curl -LsSf https://astral.sh/uv/install.sh | sh", shell=True, check=False)
        uv = str(Path.home() / ".local/bin/uv")
    ok = False
    if Path(uv).exists():
        r = run([uv, "venv", "--python", "3.11", "--seed", str(VENV)], check=False)
        ok = r.returncode == 0 and PY.exists()
    if not ok:
        log("uv khong dung duoc, dung python3 he thong")
        run([sys.executable, "-m", "venv", str(VENV)])
    version = subprocess.check_output(
        [str(PY), "-c", "import sys;print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
        text=True,
    ).strip()
    major, minor = (int(part) for part in version.split(".")[:2])
    if (major, minor) < MIN_PYTHON:
        sys.exit(f"Python {version} khong duoc ho tro; can Python >= {MIN_PYTHON[0]}.{MIN_PYTHON[1]}.")
    run([str(PY), "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"])


# ----------------------------------------------------------------------------
# 4. Ma nguon + thu vien
# ----------------------------------------------------------------------------
def install_python_deps():
    log("Clone ma nguon Wan2.2")
    BASE.mkdir(parents=True, exist_ok=True)
    if not REPO.exists():
        run(["git", "clone", REPO_URL, str(REPO)])
    else:
        if not (REPO / ".git").exists():
            sys.exit(f"{REPO} da ton tai nhung khong phai Git checkout. Hay doi WAN_BASE hoac backup thu muc nay.")
        pulled = run(["git", "-C", str(REPO), "pull", "--ff-only"], check=False)
        if pulled.returncode != 0:
            print("CANH BAO: khong fast-forward duoc repo; tiep tuc dung ma nguon dang co.")

    for required in ("requirements.txt", "requirements_animate.txt", "generate.py"):
        if not (REPO / required).exists():
            sys.exit(f"Repo Wan2.2 thieu {required}: {REPO}")

    log("Cai PyTorch (CUDA 12.8)")
    run([str(PY), "-m", "pip", "install", *TORCH_SPEC, "--index-url", TORCH_INDEX])

    # Loai flash_attn/torch/SAM-2 khoi requirements de cai rieng
    sam_lines = []

    def filtered(req: Path) -> Path:
        out = BASE / f"filtered_{req.name}"
        lines = []
        for ln in req.read_text().splitlines():
            low = ln.lower()
            if "sam2" in low or "sam-2" in low:
                sam_lines.append(ln.strip())
                continue
            key = re.split(r"[<>=!~\[ ;@]", ln.strip(), maxsplit=1)[0].lower().replace("-", "_")
            if key in ("flash_attn", "torch", "torchvision", "torchaudio", "opencv_python"):
                continue
            lines.append(ln)
        out.write_text("\n".join(lines) + "\n")
        return out

    log("Cai requirements.txt")
    run([str(PY), "-m", "pip", "install", "-r", str(filtered(REPO / "requirements.txt"))])

    log("Cai requirements_animate.txt (tien xu ly pose/mask cho Animate)")
    animate_req = REPO / "requirements_animate.txt"
    if animate_req.exists():
        run([str(PY), "-m", "pip", "install", "-r", str(filtered(animate_req))])
    else:
        print("Khong thay requirements_animate.txt - bo qua (kiem tra README cua repo).")

    log("Cai SAM-2 (khong build, chi clone dung commit + .pth)")
    spec = next((line for line in sam_lines if "sam2" in line.lower() or "sam-2" in line.lower()), "")
    m = re.search(r"@([0-9a-f]{7,40})", spec)
    if not m:
        sys.exit("Khong doc duoc commit SAM-2 tu requirements_animate.txt; dung de tranh cai sai phien ban.")
    sam_dir = BASE / "sam2"
    if not sam_dir.exists():
        run(["git", "clone", "https://github.com/facebookresearch/sam2.git", str(sam_dir)])
    run(["git", "-C", str(sam_dir), "checkout", m.group(1)])
    run([str(PY), "-m", "pip", "install", "hydra-core>=1.3.2", "iopath>=0.1.10", "omegaconf"])
    site = subprocess.check_output(
        [str(PY), "-c", "import sysconfig;print(sysconfig.get_paths()['purelib'])"], text=True
    ).strip()
    (Path(site) / "sam2_local.pth").write_text(str(sam_dir) + "\n")
    run([str(PY), "-c",
         "import sam2, sam2.build_sam;print('SAM-2 OK:', sam2.__file__)"])

    log("Ghim numpy<2 (Wan can numpy 1.x)")
    run([str(PY), "-m", "pip", "install", "numpy<2"])

    log("Cai OpenCV tuong thich voi numpy<2")
    run([str(PY), "-m", "pip", "install", "opencv-python==4.11.0.86"])

    log("Cai thu vien bo sung cho tien xu ly (moviepy, scipy, scikit-image)")
    run([str(PY), "-m", "pip", "install", "moviepy", "scipy", "scikit-image", "numpy<2"])

    log("Cai gradio + huggingface_hub")
    run([str(PY), "-m", "pip", "install", "gradio>=5,<6", "huggingface_hub>=0.36,<1.0"])

    log("Cai librosa + soundfile (module wan import can cho audio/S2V)")
    run([str(PY), "-m", "pip", "install", "librosa", "soundfile", "numpy<2"])

    log("Go hf-gradio (goi thua, gay canh bao pip check voi gradio-client)")
    run([str(PY), "-m", "pip", "uninstall", "-y", "hf-gradio"], check=False)

    log("Ghim lai numpy<2 sau khi cai librosa/numba")
    run([str(PY), "-m", "pip", "install", "numpy<2"])

    log("Thu cai hf_transfer (tang toc tai model, khong bat buoc)")
    r = run([str(PY), "-m", "pip", "install", "hf_transfer"], check=False)
    if r.returncode != 0:
        print("hf_transfer khong cai duoc; script se tai model bang che do mac dinh.")

    log("Thu cai flash-attn (khong bat buoc; loi cung khong sao)")
    r = run([str(PY), "-m", "pip", "install", "flash-attn", "--no-build-isolation"], check=False)
    if r.returncode != 0:
        print("flash-attn khong cai duoc -> Wan se dung attention mac dinh cua PyTorch.")

    log("Kiem tra CUDA trong PyTorch")
    run([str(PY), "-c",
         "import torch;print('torch',torch.__version__);print('cuda',torch.cuda.is_available());"
         "print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NO GPU');"
         "print(torch.cuda.get_device_capability(0) if torch.cuda.is_available() else '')"])


def verify_install():
    """Fail early if a required Python module, Wan preprocessor import, or CUDA is missing."""
    log("Kiem tra pip check va import cac thu vien Animate")
    result = subprocess.run(
        [str(PY), "-m", "pip", "check"],
        capture_output=True,
        text=True,
        check=False,
    )
    details = (result.stdout + "\n" + result.stderr).strip()
    if details:
        print(details, flush=True)
    else:
        details = "(pip check returned no diagnostic text)"
        print(details, flush=True)
    report_path = BASE / "pip-check.log"
    report_path.write_text(
        f"Python: {PY}\nExit code: {result.returncode}\n\n{details}\n",
        encoding="utf-8",
    )
    if result.returncode != 0:
        print(
            "CANH BAO: pip check phat hien dependency conflict hoac loi kiem tra; "
            f"log duoc luu tai {report_path}. Tiep tuc kiem tra cac import bat buoc va CUDA.",
            flush=True,
        )

    env = dict(os.environ)
    preprocess = REPO / "wan/modules/animate/preprocess"
    env["PYTHONPATH"] = os.pathsep.join(
        [str(REPO), str(preprocess), env.get("PYTHONPATH", "")]
    ).rstrip(os.pathsep)
    code = textwrap.dedent(
        """
        import importlib
        import sys

        required = [
            "torch", "torchvision", "torchaudio", "PIL", "cv2", "diffusers",
            "transformers", "tokenizers", "accelerate", "tqdm", "imageio",
            "imageio_ffmpeg", "easydict", "ftfy", "decord", "peft",
            "onnxruntime", "pandas", "matplotlib", "loguru", "sentencepiece",
            "scipy", "skimage", "gradio", "huggingface_hub", "hydra",
            "iopath", "omegaconf", "moviepy", "sam2", "sam2.build_sam",
            "sam2.modeling.sam.transformer", "process_pipepline", "wan",
        ]
        failed = []
        for name in required:
            try:
                importlib.import_module(name)
                print("OK   ", name)
            except Exception as exc:
                failed.append((name, repr(exc)))
                print("FAIL ", name, repr(exc))
        if failed:
            sys.exit(2)

        import torch
        if not torch.cuda.is_available():
            print("FAIL CUDA: torch.cuda.is_available() is False")
            sys.exit(3)
        device = torch.cuda.get_device_name(0)
        capability = torch.cuda.get_device_capability(0)
        memory_gb = torch.cuda.get_device_properties(0).total_memory / (1024 ** 3)
        probe = torch.ones((1,), device="cuda")
        torch.cuda.synchronize()
        print(f"CUDA OK: {device}; capability={capability}; VRAM={memory_gb:.1f} GB; probe={probe.item()}")
        try:
            import flash_attn
            print("OK    flash_attn (optional acceleration)")
        except Exception:
            print("INFO  flash_attn absent; Wan uses its PyTorch attention fallback")
        """
    )
    chk = run([str(PY), "-c", code], env=env, check=False)
    if chk.returncode == 2:
        log("Import that bai - in traceback day du cua tung module loi de xac dinh package thieu")
        diag = (
            "import importlib, traceback\n"
            "for n in ('wan','process_pipepline','sam2.build_sam','decord'):\n"
            "    try:\n"
            "        importlib.import_module(n)\n"
            "    except Exception:\n"
            "        print('=== FAIL', n); traceback.print_exc()\n"
        )
        run([str(PY), "-c", diag], env=env, check=False)
        sys.exit(
            "Co module import FAIL (xem cac dong 'FAIL ...' va traceback o tren). "
            "Cai package con thieu bang: " + str(PY) + " -m pip install <ten-goi> 'numpy<2'"
        )
    elif chk.returncode != 0:
        sys.exit(f"Kiem tra CUDA that bai (ma {chk.returncode}); xem log o tren.")
    if result.returncode != 0:
        log("Import cac thu vien chinh va CUDA deu dat; tiep tuc voi pip-check warning.")


# ----------------------------------------------------------------------------
# 5. Tai model
# ----------------------------------------------------------------------------
def missing_model_files():
    missing = [relative for relative in MODEL_FILES if not (CKPT / relative).is_file()]
    for relative in MODEL_DIRS:
        path = CKPT / relative
        if not path.is_dir() or not any(path.rglob("*")):
            missing.append(relative + "/ (checkpoint folder)")
    return missing


def download_model():
    marker = CKPT / ".download_complete"
    missing = missing_model_files()
    if not missing:
        log("Da co du file checkpoint; bo qua tai model")
        marker.touch(exist_ok=True)
        return
    if marker.exists():
        log("Marker cu ton tai nhung checkpoint thieu file; tiep tuc tai/resume")
    log(f"Tai model {HF_REPO} (khoang 55-60 GB) -> {CKPT}")
    code = (
        "from huggingface_hub import snapshot_download;"
        f"snapshot_download(repo_id='{HF_REPO}', local_dir=r'{CKPT}')"
    )
    env = dict(os.environ, HF_HUB_ENABLE_HF_TRANSFER="1")
    r = run([str(PY), "-c", code], env=env, check=False)
    if r.returncode != 0:
        print("hf_transfer khong chay duoc; thu tai lai bang download mac dinh...")
        env.pop("HF_HUB_ENABLE_HF_TRANSFER", None)
        run([str(PY), "-c", code], env=env)
    missing = missing_model_files()
    if missing:
        sys.exit("Tai model chua day du, thieu: " + ", ".join(missing))
    marker.touch(exist_ok=True)


# ----------------------------------------------------------------------------
# 6. Giao dien web (Gradio)
# ----------------------------------------------------------------------------
APP_CODE = r'''
import os, subprocess, sys, uuid
from pathlib import Path
import gradio as gr

REPO = Path("__REPO__")
CKPT = Path("__CKPT__")
WORK = Path("__WORK__")
PY = sys.executable
PORT = int(os.environ.get("WAN_PORT", "7860"))
USER = os.environ.get("WAN_USER", "admin")
PASS = os.environ.get("WAN_PASS", "changeme")

RES = {
    "480p (832x480) - nhanh": (832, 480),
    "720p (1280x720) - chat luong cao": (1280, 720),
}


def sh(cmd):
    env = dict(os.environ, PYTHONPATH=os.pathsep.join(
        [str(REPO), str(REPO / "wan/modules/animate/preprocess")]))
    env.pop("PYTHONSAFEPATH", None)  # cho phep import tran trong thu muc preprocess
    p = subprocess.run([str(c) for c in cmd], cwd=REPO, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        tail = (p.stdout + "\n" + p.stderr)[-3500:]
        raise gr.Error("Loi:\n" + tail)
    return p.stdout


def process(video, image, mode, res, relight, refert, progress=gr.Progress()):
    if not video or not image:
        raise gr.Error("Can tai len ca video goc va anh nhan vat.")
    replace = mode.startswith("Replace")
    w, h = RES[res]
    job = WORK / uuid.uuid4().hex[:8]
    proc = job / "process"
    proc.mkdir(parents=True, exist_ok=True)
    out_file = job / "result.mp4"

    progress(0.05, desc="Tien xu ly: pose / mask / khuon mat...")
    pre = [PY, "wan/modules/animate/preprocess/preprocess_data.py",
           "--ckpt_path", CKPT / "process_checkpoint",
           "--video_path", video, "--refer_path", image,
           "--save_path", proc, "--resolution_area", w, h]
    if replace:
        pre += ["--iterations", 3, "--k", 7, "--w_len", 1, "--h_len", 1, "--replace_flag"]
    else:
        pre += ["--retarget_flag"]
    sh(pre)

    progress(0.3, desc="Sinh video (buoc nay lau)...")
    gen = [PY, "generate.py", "--task", "animate-14B", "--ckpt_dir", CKPT,
           "--src_root_path", proc, "--refert_num", int(refert),
           "--save_file", out_file]
    if replace:
        gen += ["--replace_flag"]
        if relight:
            gen += ["--use_relighting_lora"]
    sh(gen)

    if not out_file.exists():
        found = sorted(REPO.glob("*.mp4"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not found:
            raise gr.Error("Khong tim thay file ket qua.")
        out_file = found[0]
    progress(1.0, desc="Xong")
    return str(out_file)


CSS = r"""
:root, .gradio-container {
    --body-background-fill: #090d18;
    --block-background-fill: #111827;
    --block-border-color: rgba(148, 163, 184, .16);
    --body-text-color: #e5e7eb;
    --body-text-color-subdued: #9ca3af;
    --button-primary-background-fill: #7c3aed;
    --button-primary-background-fill-hover: #6d28d9;
}
.gradio-container {
    max-width: 1440px !important;
    margin: 0 auto !important;
    padding: 24px !important;
    background:
        radial-gradient(ellipse at 15% 0%, rgba(124, 58, 237, .16), transparent 36%),
        #090d18 !important;
}
#app-shell { gap: 18px; }
#hero {
    padding: 28px 32px;
    border: 1px solid rgba(167, 139, 250, .25);
    border-radius: 22px;
    background: linear-gradient(120deg, rgba(91, 33, 182, .30), rgba(17, 24, 39, .96) 68%);
}
#hero h1 { margin: 4px 0 10px; font-size: clamp(26px, 4vw, 40px); }
#hero p { color: #cbd5e1; max-width: 760px; }
.panel {
    border: 1px solid rgba(148, 163, 184, .16) !important;
    border-radius: 18px !important;
    background: rgba(17, 24, 39, .88) !important;
    padding: 18px !important;
}
.section-title h2 { font-size: 18px; margin: 0 0 10px; }
#run-button {
    min-height: 54px;
    font-size: 16px;
    font-weight: 700;
    border-radius: 12px;
}
#clear-button { min-height: 46px; border-radius: 12px; }
#status-panel textarea { min-height: 72px; }
#result-panel { min-height: 300px; }
.hint { color: #9ca3af; font-size: 13px; }
@media (max-width: 760px) {
    .gradio-container { padding: 12px !important; }
    #hero { padding: 22px 18px; }
    .panel { padding: 14px !important; }
}
"""


def mark_running():
    return "Đang chuẩn bị tác vụ… Tiến trình sẽ hiển thị các bước xử lý bên dưới."


def run_job(video, image, mode, res, relight, refert, progress=gr.Progress()):
    try:
        result = process(video, image, mode, res, relight, refert, progress)
        return result, result, "✅ Hoàn tất. Video đã sẵn sàng để xem hoặc tải xuống."
    except Exception as exc:
        message = str(exc).strip() or type(exc).__name__
        return None, None, f"⚠️ Xử lý thất bại: {message[:2500]}"


with gr.Blocks(
    title="Wan2.2 Animate · Video Studio",
    theme=gr.themes.Soft(primary_hue="violet", neutral_hue="slate"),
    css=CSS,
) as demo:
    with gr.Column(elem_id="app-shell"):
        gr.HTML(
            """
            <div id="hero">
              <div style="color:#c4b5fd;font-weight:700;letter-spacing:.12em;text-transform:uppercase">
                Wan2.2 · Animate 14B
              </div>
              <h1>Video Character Studio</h1>
              <p>Tạo video nhân vật mới từ chuyển động trong video tham chiếu. Bắt đầu với clip 3–5 giây có một nhân vật để kiểm tra nhanh.</p>
            </div>
            """
        )

        with gr.Row(equal_height=True):
            with gr.Column(scale=6, elem_classes=["panel"]):
                gr.Markdown("## 01 · Tệp đầu vào", elem_classes=["section-title"])
                vid = gr.Video(label="Video chuyển động gốc")
                img = gr.Image(
                    type="filepath",
                    label="Ảnh nhân vật tham chiếu",
                    height=300,
                )
                gr.Markdown(
                    "Tải lên video gốc và ảnh nhân vật. Ảnh rõ mặt, đủ sáng thường cho kết quả tốt hơn.",
                    elem_classes=["hint"],
                )

            with gr.Column(scale=5, elem_classes=["panel"]):
                gr.Markdown("## 02 · Cấu hình", elem_classes=["section-title"])
                mode = gr.Radio(
                    [
                        "Replace · Thay nhân vật, giữ cảnh gốc",
                        "Animate · Tạo chuyển động từ ảnh",
                    ],
                    value="Replace · Thay nhân vật, giữ cảnh gốc",
                    label="Chế độ xử lý",
                )
                res = gr.Dropdown(
                    list(RES),
                    value="480p (832x480) - nhanh",
                    label="Độ phân giải",
                )
                relight = gr.Checkbox(
                    value=True,
                    label="Relighting LoRA · Ánh sáng tự nhiên (Replace)",
                )
                refert = gr.Radio(
                    [1, 5],
                    value=1,
                    label="Số frame tham chiếu giữa các đoạn",
                )
                gr.Markdown(
                    "720p cần nhiều thời gian và VRAM hơn. Relighting chỉ được áp dụng ở chế độ Replace.",
                    elem_classes=["hint"],
                )
                run_btn = gr.Button(
                    "▶  Bắt đầu tạo video",
                    variant="primary",
                    elem_id="run-button",
                )
                clear_btn = gr.Button("Xóa lựa chọn", elem_id="clear-button")

        with gr.Row():
            with gr.Column(elem_classes=["panel"], elem_id="result-panel"):
                gr.Markdown("## 03 · Kết quả", elem_classes=["section-title"])
                status = gr.Textbox(
                    label="Trạng thái",
                    value="Sẵn sàng. Tải video và ảnh nhân vật để bắt đầu.",
                    interactive=False,
                    lines=2,
                    elem_id="status-panel",
                )
                out = gr.Video(label="Video đã xử lý")
                download = gr.File(label="Tải video MP4")

        gr.Markdown(
            "---\n"
            "Wan2.2-Animate-14B · Xử lý trên máy chủ · Chỉ truy cập qua đăng nhập",
            elem_classes=["hint"],
        )

    run_event = run_btn.click(
        fn=mark_running,
        inputs=[],
        outputs=[status],
        queue=False,
    )
    run_event.then(
        fn=run_job,
        inputs=[vid, img, mode, res, relight, refert],
        outputs=[out, download, status],
    )
    clear_btn.click(
        fn=lambda: (
            None,
            None,
            None,
            None,
            "Sẵn sàng. Tải video và ảnh nhân vật để bắt đầu.",
        ),
        inputs=[],
        outputs=[vid, img, out, download, status],
        queue=False,
    )

demo.queue(max_size=4, default_concurrency_limit=1)
demo.launch(server_name="127.0.0.1", server_port=PORT, auth=(USER, PASS), max_file_size="500mb")
'''


def write_app():
    log("Ghi giao dien web")
    WORK.mkdir(parents=True, exist_ok=True)
    code = APP_CODE.replace("__REPO__", str(REPO)).replace("__CKPT__", str(CKPT)).replace("__WORK__", str(WORK))
    APP.write_text(code)


def get_credentials(reset=False):
    if CRED.exists() and not reset:
        parts = CRED.read_text().split()
        if len(parts) >= 2:
            return parts[0], parts[1]
    user, pw = "admin", secrets.token_hex(8)  # chi gom 0-9a-f, khong co ky tu de nham
    CRED.write_text(f"{user} {pw}\n")
    CRED.chmod(0o600)
    log(f"Da tao thong tin dang nhap moi -> {CRED}")
    return user, pw


def kill_stale():
    """Dung UI/tunnel cu con chay (nguyen nhan pho bien: URL tro vao UI cu voi mat khau cu)."""
    log("Dung UI va tunnel Pinggy cu (neu co)")
    for pattern in (str(APP), str(BASE / "pinggy_key")):
        subprocess.run(["pkill", "-f", pattern], check=False)
    time.sleep(2)
    import socket
    with socket.socket() as sk:
        sk.settimeout(1)
        if sk.connect_ex(("127.0.0.1", PORT_DEFAULT)) == 0:
            print(f"CANH BAO: cong {PORT_DEFAULT} van bi tien trinh khac giu; dung --port khac neu UI loi.")


def check_login(port, user, pw, base_url=None):
    """Dang nhap that vao Gradio (POST /login) de xac nhan tai khoan dung."""
    import urllib.parse, urllib.request, urllib.error
    url = (base_url or f"http://127.0.0.1:{port}").rstrip("/") + "/login"
    data = urllib.parse.urlencode({"username": user, "password": pw}).encode()
    req = urllib.request.Request(url, data=data, headers={"User-Agent": "wan-check"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status == 200
    except urllib.error.HTTPError as e:
        return False if e.code in (400, 401, 403) else None
    except Exception:
        return None


# ----------------------------------------------------------------------------
# 7. Chay UI + Pinggy
# ----------------------------------------------------------------------------
def start_ui(port, user, pw):
    log(f"Khoi dong giao dien tren 127.0.0.1:{port}")
    env = dict(os.environ, WAN_PORT=str(port), WAN_USER=user, WAN_PASS=pw,
               GRADIO_ANALYTICS_ENABLED="False")
    logf = open(BASE / "ui.log", "a")
    proc = subprocess.Popen([str(PY), str(APP)], env=env, stdout=logf, stderr=subprocess.STDOUT,
                            start_new_session=True)
    for _ in range(90):
        time.sleep(1)
        if proc.poll() is not None:
            sys.exit(f"UI thoat som, xem log: {BASE / 'ui.log'}")
        try:
            import urllib.request
            urllib.request.urlopen(f"http://127.0.0.1:{port}", timeout=2)
            return proc
        except Exception:
            pass
    sys.exit(f"UI khong len sau 90s, xem log: {BASE / 'ui.log'}")


def start_pinggy(port, token):
    """Mo tunnel Pinggy qua SSH (cong 443). Ghi output ra file de khong bi day pipe.
    Tra ve (process, url)."""
    # Pinggy can user dang "free@" (ban free) hoac "TOKEN+" (ban pro), host a.pinggy.io
    target = f"{token}+a.pinggy.io" if token else "free@a.pinggy.io"

    # Pinggy chap nhan bat ky khoa SSH nao -> tu tao khoa rieng (khong passphrase)
    key = BASE / "pinggy_key"
    if not key.exists():
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
    # Du phong: neu server doi mat khau thi tra loi mat khau rong qua SSH_ASKPASS
    askpass = BASE / "askpass.sh"
    askpass.write_text("#!/bin/sh\necho ''\n")
    askpass.chmod(0o755)
    env = dict(os.environ, SSH_ASKPASS=str(askpass), SSH_ASKPASS_REQUIRE="force",
               DISPLAY=os.environ.get("DISPLAY", ":0"))

    cmd = ["ssh", "-p", "443", "-T", "-i", str(key), "-o", "IdentitiesOnly=yes",
           "-o", "NumberOfPasswordPrompts=1", f"-R0:localhost:{port}",
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes", target]
    log("Mo Pinggy: " + " ".join(cmd).replace(token or "\0", "***"))
    logpath = BASE / "pinggy.log"
    logf = open(logpath, "w")
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT, env=env,
                            start_new_session=True)
    ansi = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
    pat = re.compile(r"https://[A-Za-z0-9.\-]*pinggy[A-Za-z0-9.\-]*")
    skip = re.compile(r"//(www\.|dashboard\.|a\.|free\.|pro\.)?pinggy\.io")
    deadline = time.time() + 45
    while time.time() < deadline:
        time.sleep(1)
        text = ansi.sub("", logpath.read_text(errors="ignore"))
        for u in pat.findall(text):
            if not skip.search(u):
                return proc, u
        if proc.poll() is not None:
            break
    print("--- Output Pinggy ---\n" + ansi.sub("", logpath.read_text(errors="ignore"))[-1500:])
    return proc, None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--check-only", action="store_true",
                    help="Chi kiem tra Linux, NVIDIA GPU va dung luong dia; khong cai dat.")
    ap.add_argument("--skip-install", action="store_true")
    ap.add_argument("--install-only", action="store_true",
                    help="Cai thu vien/model va kiem tra, sau do thoat, khong mo web UI.")
    ap.add_argument("--skip-model-download", action="store_true",
                    help="Bo qua tai model; chi duoc dung cung --install-only.")
    ap.add_argument("--no-tunnel", action="store_true")
    ap.add_argument("--reset-credentials", action="store_true",
                    help="Tao lai tai khoan/mat khau moi va dung UI+tunnel cu.")
    ap.add_argument("--diagnose", action="store_true",
                    help="Chay kiem tra import/CUDA bang Python roi thoat.")
    ap.add_argument("--pinggy-token", default=os.environ.get("PINGGY_TOKEN"))
    ap.add_argument("--port", type=int, default=PORT_DEFAULT)
    a = ap.parse_args(argv)

    if a.skip_model_download and not a.install_only:
        ap.error("--skip-model-download chi dung cung --install-only.")
    if not 1 <= a.port <= 65535:
        ap.error("--port phai nam trong khoang 1-65535.")

    if a.check_only:
        check_system()
        log("Preflight dat. Chua cai dat hoac tai model.")
        return

    BASE.mkdir(parents=True, exist_ok=True)
    if a.diagnose:
        if not PY.exists():
            sys.exit("Chua co virtualenv.")
        verify_install()
        log("Diagnose xong: import va CUDA deu dat.")
        return
    if not a.skip_install:
        check_system()
        install_apt()
        make_venv()
        install_python_deps()
    else:
        if not PY.exists():
            sys.exit("Chua co virtualenv. Chay lai khong kem --skip-install.")
        if not (REPO / "generate.py").exists():
            sys.exit(f"Khong tim thay ma nguon Wan2.2 tai {REPO}. Chay lai khong kem --skip-install.")

    verify_install()
    if a.skip_model_download:
        log("Bo qua model theo yeu cau; cac buoc cai dat va import library da kiem tra.")
    else:
        download_model()
    if a.install_only:
        log("Cai dat va kiem tra hoan tat. Chay lai script de mo web UI.")
        return
    if missing_model_files():
        sys.exit("Checkpoint chua day du. Chay lai script khong kem --skip-model-download.")

    write_app()
    kill_stale()
    user, pw = get_credentials(reset=a.reset_credentials)
    ui = start_ui(a.port, user, pw)
    ok = check_login(a.port, user, pw)
    if ok is False:
        sys.exit("Dang nhap thu local THAT BAI voi tai khoan vua tao; xem " + str(BASE / "ui.log"))
    print("Kiem tra dang nhap local:", "OK" if ok else "khong xac dinh", flush=True)

    tunnel = None
    url = None
    if not a.no_tunnel:
        tunnel, url = start_pinggy(a.port, a.pinggy_token)
        if not url:
            print("CANH BAO: khong mo duoc Pinggy; UI van chay local, khong co URL cong khai.")
            if tunnel and tunnel.poll() is None:
                tunnel.terminate()
            tunnel = None

    if url:
        t = check_login(a.port, user, pw, base_url=url)
        print("Kiem tra dang nhap qua tunnel:", {True: "OK", False: "SAI", None: "khong xac dinh"}[t], flush=True)

    print("\n" + "=" * 62)
    print(f" URL      : {url or ('http://127.0.0.1:%d (chi local)' % a.port)}")
    print(f" Tai khoan: {user}")
    print(f" Mat khau : {pw}   (luu tai {CRED})")
    if not a.pinggy_token:
        print(" Luu y    : Pinggy ban free het han sau ~60 phut, script se tu mo lai tunnel (URL doi).")
    print(" Dung Ctrl+C de dung.")
    print("=" * 62 + "\n", flush=True)

    state = {"tunnel": tunnel, "ui": ui}

    def watch(forever_exit):
        while True:
            time.sleep(5)
            if state["ui"].poll() is not None:
                msg = f"UI da dung, xem {BASE / 'ui.log'}"
                if forever_exit:
                    sys.exit(msg)
                print(msg, flush=True)
                return
            t = state["tunnel"]
            if t and t.poll() is not None:
                print("Tunnel bi ngat, mo lai...", flush=True)
                state["tunnel"], new_url = start_pinggy(a.port, a.pinggy_token)
                if new_url:
                    print(f"\n URL moi: {new_url}\n", flush=True)

    if IN_NOTEBOOK:
        # Khong chan cell: UI + tunnel chay nen, luong phu tu mo lai tunnel khi bi ngat.
        threading.Thread(target=watch, args=(False,), daemon=True).start()
        print("Dang chay nen. De dung: goi stop() trong mot cell.", flush=True)
        return

    try:
        watch(True)
    except KeyboardInterrupt:
        pass
    finally:
        for p in (state["tunnel"], state["ui"]):
            if p and p.poll() is None:
                p.terminate()


def stop():
    """Dung UI va tunnel (dung trong notebook)."""
    kill_stale()
    log("Da dung.")


def run_cli():
    """Terminal: dung sys.argv. Notebook: dung NOTEBOOK_ARGS va khong de SystemExit lam hong cell."""
    try:
        main(NOTEBOOK_ARGS if IN_NOTEBOOK else None)
    except SystemExit as e:
        if e.code not in (None, 0):
            print(f"\n[DUNG] {e.code}", flush=True)
        if not IN_NOTEBOOK:
            raise


if __name__ == "__main__":
    run_cli()
