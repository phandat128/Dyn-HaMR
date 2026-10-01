# Installing ViPE for Dyn-HaMR (egoexo container)

[ViPE](https://github.com/nv-tlabs/vipe) replaces DROID-SLAM as Dyn-HaMR's
camera-estimation backend. This document is the reproducible install for
**this repository's container**, where upstream's instructions do not apply.

> **Heads up:** this installs ViPE into the container's **system Python 3.12**
> and upgrades four packages that `requirements.txt` still pins to older
> versions. Read [Divergences from upstream](#divergences-from-upstream) and
> [Effect on the rest of the repo](#effect-on-the-rest-of-the-repo) before
> running it on an environment you care about.

## Why not upstream's instructions

`third-party/vipe/README.md` says to create a conda env from `envs/base.yml`
(python 3.10, `cuda-nvcc`, `eigen`) and install pinned `torch==2.7.0+cu128`.
None of that works here as written:

- **There is no conda in this image**, and adding a Miniconda toolchain is not
  part of the `Dockerfile`.
- **The base image already ships a CUDA-matched torch** — `2.7.0a0+...nv25.03`
  built against CUDA 12.8 — plus `nvcc` 12.8 at `/usr/local/cuda`. `pyproject.toml`
  deliberately reuses that build rather than reinstalling torch. A second env
  would duplicate a multi-GB CUDA stack to get the same ABI.
- ViPE's only hard requirements are python ≥3.10, a CUDA torch, and `nvcc` to
  build its extension. The system env satisfies all three.

So we install into the system env and build the extension against the torch
that is already there.

## Prerequisites

Already true in the `egoexo` container; listed so this is checkable:

| Requirement | Verify with | Expected |
|---|---|---|
| CUDA toolkit (for `nvcc`) | `nvcc --version` | 12.8 |
| CUDA-enabled torch | `python3 -c "import torch;print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"` | `2.7.0a0+…nv25.03 12.8 True` |
| GPU | `nvidia-smi` | any; ViPE needs roughly 10 GB VRAM with `no_vda` |
| Submodule checked out | `ls third-party/vipe/pyproject.toml` | exists |

If `third-party/vipe` is empty: `git submodule update --init --recursive`.

## Install

Run from the repository root. Every step is idempotent.

### 1. System libraries

ViPE's CUDA extension `#include`s Eigen, and `OpenEXR` needs its C library.

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    libeigen3-dev libopenexr-dev zlib1g-dev
```

### 2. Python dependencies

Only the packages the base image lacks. `--no-cache-dir` keeps the image small;
torch and torchvision are deliberately **not** listed, so pip never replaces the
NVIDIA build.

```bash
pip install --no-cache-dir python-pycg OpenEXR viser ray
```

This pulls `numpy>=2` as a transitive dependency, which conflicts with this
repo's `numpy==1.26.4` pin. Put it back, and pin `plyfile` to the last release
that accepts numpy 1.x:

```bash
pip install --no-cache-dir "numpy==1.26.4" "plyfile<1.1.1" "packaging==23.2"
```

### 3. Version upgrades ViPE requires

Four packages pinned older in `requirements.txt` must move for ViPE to import
and run. Each is justified in [Divergences](#divergences-from-upstream).

```bash
pip install --no-cache-dir \
    "hydra-core==1.3.2" "omegaconf==2.3.0" "antlr4-python3-runtime==4.9.3" \
    "timm==1.0.14" \
    "kornia==0.8.0" \
    "gdown==5.2.0"
```

### 4. Build and install ViPE

`CPATH` points the compiler at Eigen (upstream gets this from the conda prefix,
which does not exist here). `--no-build-isolation` makes the build reuse the
installed torch; `--no-deps` stops pip re-resolving the pins set above.

```bash
cd external/Dyn-HaMR/third-party/vipe
CPATH=/usr/include/eigen3 MAX_JOBS=16 \
    pip install --no-build-isolation --no-deps -e .
```

The CUDA extension takes several minutes to compile.

### 5. Verify

```bash
python3 -c "import vipe, vipe_ext; from vipe.ext import _C; print(vipe.__version__)"
vipe infer --help
```

Expect `0.1.1+pt27cu128` and the CLI's usage text. The `+pt27cu128` suffix
confirms it built against torch 2.7 / CUDA 12.8.

## Resulting versions

```
vipe          0.1.1+pt27cu128   hydra-core   1.3.2     numpy      1.26.4
torch         2.7.0a0+…nv25.03  omegaconf    2.3.0     packaging  23.2
timm          1.0.14            python-pycg  1.0.3     plyfile    1.1
kornia        0.8.0             viser        1.1.1     OpenEXR    3.5.0
gdown         5.2.0             ray          2.58.0
```

## Divergences from upstream

| Upstream | Here | Why |
|---|---|---|
| conda env `vipe`, python 3.10 | system python 3.12 | no conda in this image; base torch is already CUDA-matched |
| `torch==2.7.0+cu128` from the PyTorch index | base image's `2.7.0a0+…nv25.03` | same major/CUDA ABI; avoids a duplicate multi-GB CUDA stack |
| `pip install -r envs/requirements.txt` (pins everything) | install only the 4 missing packages | that file pins `numpy==2.1.2` and would overwrite this repo's torch |
| Eigen from the conda prefix | `libeigen3-dev` + `CPATH` | `vipe/ext/specs.py` only adds an include path when `CONDA_PREFIX` is set |

### Package upgrades, and why each is safe

These change the shared environment. Each was checked against the other consumers:

- **`hydra-core` 1.1.0 → 1.3.2** (+ `omegaconf`, `antlr4`). 1.1.0 is **already
  broken on python 3.12** — importing it raises `ValueError: mutable default
  … for field override_dirname`. Nothing in `egoexo/` imports hydra;
  `pyproject.toml`'s own comment marks this pin as reserved for a
  not-yet-vendored EgoHOS backend. Dyn-HaMR needs ≥1.2 anyway (it uses
  `version_base` and `hydra.job.chdir`).
- **`timm` 0.4.9 → 1.0.14.** ViPE's GroundingDINO imports `timm.layers`, added
  in 0.9. HaMeR uses the older `timm.models.layers`, which 1.0.14 still
  provides as a deprecation shim — both import paths were verified to work.
- **`kornia` 0.5.0 → 0.8.0.** ViPE calls `kornia.geometry.transform.resize(...,
  antialias=True)`, which 0.5.0 lacks. Every `kornia` mention in `egoexo/` and
  in both HaMeR checkouts is an attribution comment in vendored code — nothing
  imports it.
- **`gdown` 6.4.0 → 5.2.0** (a *downgrade*). ViPE calls
  `gdown.download(..., fuzzy=True)`; the installed 6.4.0 had dropped that
  keyword. Only used by download scripts.

## Effect on the rest of the repo

The upgrades above are **global** — they mutate the environment shared with the
inpainting and ego_replay stages. Two consequences:

1. `requirements.txt` and `pyproject.toml` still pin the old versions, so
   `docker compose build` or `pip install -r requirements.txt` reverts them and
   ViPE stops working. **To make this durable, update those pins** to match
   [Resulting versions](#resulting-versions).
2. HaMeR inference under `timm` 1.0.14 / `kornia` 0.8.0 has been verified at
   *import* level only, not by a full run.

## Biomechanical constraints (BMC)

`dyn-hamr/optim/losses.py` constructs `BMCLoss` **unconditionally**, even
though the `bio` loss weight is `[0, 0, 0]` by default. Its `__init__` eagerly
loads seven `.npy` tables, so without them any run dies with:

```
FileNotFoundError: .../dyn-hamr/optim/../../_DATA/BMC/bone_len_max.npy
```

These tables encode anatomical limits (bone lengths, root-bone curvature and
angular distance, and per-joint angle convex hulls). They are **not
downloadable** -- upstream expects you to compute them from pooled 3D hand-joint
data. To do that:

```bash
scripts/prepare_bmc.sh
```

This clones [Hand-BMC-pytorch](https://github.com/MengHao666/Hand-BMC-pytorch),
downloads ~91 MB of joint data (RHD, GANerated, STB, FreiHAND -- each under its
own license), runs both calculation stages, and installs the result into
`_DATA/BMC/`. It takes a few minutes and is idempotent.

Note the README and the code disagree on the location: the README says
`dyn-hamr/optim/BMC/`, but `bio_loss.py` loads from `_DATA/BMC/`. The script
follows the code.

The script applies one fix to upstream Hand-BMC-pytorch: `np.array(all_del_hulls)`
cannot infer a ragged array under numpy >= 1.24 (the 15 hulls have different
vertex counts), so it passes `dtype=object` -- which is what `bio_loss.py`'s
`allow_pickle=True` load expects anyway.

## Running Dyn-HaMR with ViPE

```bash
scripts/run_dynhamr_vipe.sh [RECORDING_DIR]
```

Defaults to `recordings/19700101T082533+08`. The script runs ViPE, then
Dyn-HaMR's own pipeline (frame extraction → HaMeR tracking → camera conversion
→ optimization), skipping any stage whose output already exists.

The first run additionally downloads roughly 2.5 GB of model weights
(GeoCalib, DROID, SAM, AOT, GroundingDINO's BERT, UniDepth) into
`~/.cache/torch/hub` and `~/.cache/huggingface`. Set `TORCH_HOME` / `HF_HOME`
to relocate them. `VIPE_PIPELINE=default` enables Video-Depth-Anything for
better depth, at a larger download and more VRAM; it does not change the pose
and intrinsics that Dyn-HaMR consumes.

### How the two halves connect

ViPE writes `vipe_results/pose/<stem>.npz` and
`vipe_results/intrinsics/<stem>.npz`, named after the video's filename stem.
Dyn-HaMR's `preprocess_cameras()` (`dyn-hamr/data/vidproc.py`) looks them up as
`<vipe_dir>/pose/${data.seq}.npz`, inverts ViPE's camera-to-world matrices to
world-to-camera, and writes DROID-format `cameras.npz`. **This is why
`data.seq` must be `rgb`** for an `rgb.mp4` input — see
`confs/data/video_vipe_egoexo.yaml`.

Dyn-HaMR can also invoke ViPE itself when results are missing, but its
`run_vipe()` helper shells out to `conda activate vipe` and cannot work in this
container. The script calls `vipe` directly and ensures the outputs exist
first, so that path is never reached.

## Patches applied to Dyn-HaMR

Two edits under `dyn-hamr/` were needed to run on python 3.12 / numpy 1.26,
both unrelated to ViPE itself:

- **`run_opt.py`** imported `HMP.fitting` and `human_body_prior` at module
  scope. `human_body_prior` is not vendored here, so the import failed before
  anything ran. Both are now imported lazily inside the `cfg.run_prior` branch,
  which is off by default.
- **`HMP/holden/AnimationStructure.py`** used `np.int`, removed in numpy 1.24.
  Changed to the builtin `int`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ModuleNotFoundError: No module named 'timm.layers'` | `timm` still 0.4.9 — rerun step 3 |
| `resize() got an unexpected keyword argument 'antialias'` | `kornia` still 0.5.0 — rerun step 3 |
| `download() got an unexpected keyword argument 'fuzzy'` | `gdown` too new — `pip install "gdown==5.2.0"` |
| `ValueError: mutable default … override_dirname` | `hydra-core` still 1.1.0 — rerun step 3 |
| `fatal error: eigen3/Eigen/Dense: No such file` | Eigen missing or `CPATH` unset — redo steps 1 and 4 |
| `ImportError: vipe_ext` / a JIT build starts at import | the extension did not install; rerun step 4. `VIPE_EXT_JIT=1` forces a JIT build as a fallback |
| `FileNotFoundError: …/_DATA/BMC/bone_len_max.npy` | BMC tables not generated — run `scripts/prepare_bmc.sh` |
| `ValueError: … inhomogeneous shape` while building hulls | old Hand-BMC checkout without the `dtype=object` fix; delete the work dir and rerun `prepare_bmc.sh` |
| CUDA OOM during inference | use `VIPE_PIPELINE=no_vda` (the script's default) |
