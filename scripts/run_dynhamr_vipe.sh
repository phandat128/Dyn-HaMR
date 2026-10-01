#!/usr/bin/env bash
# Run Dyn-HaMR on one recording, using ViPE (not DROID-SLAM) for camera
# estimation. See external/Dyn-HaMR/VIPE_INSTALL.md for the one-time install.
#
#   scripts/run_dynhamr_vipe.sh [RECORDING_DIR]
#
# Stages, all idempotent -- each is skipped when its output already exists:
#   1. ViPE          -> <vipe_results>/{pose,intrinsics}/rgb.npz
#   2. frames        -> RECORDING_DIR/dyn_hamr_output/images/rgb/*.jpg
#   3. HaMeR tracks  -> .../dyn_hamr_output/dynhamr/track_preds/rgb/
#   4. cameras       -> .../dyn_hamr_output/dynhamr/cameras/rgb/shot-0/cameras.npz
#   5. optimization  -> .../dyn_hamr_output/<seq-name>/{root_fit,smooth_fit}/*.npz
# Stages 2-5 all run inside the single `run_opt.py` invocation at the end.
set -euo pipefail

RECORDING="${1:-/workspace/egoexo/recordings/19700101T082533+08}"
RECORDING="$(cd "$RECORDING" && pwd)"
VIDEO="$RECORDING/rgb.mp4"
OUT_DIR="$RECORDING/dyn_hamr_output"

DYNHAMR_ROOT="/workspace/egoexo/external/Dyn-HaMR"
VIPE_ROOT="$DYNHAMR_ROOT/third-party/vipe"
VIPE_RESULTS="$VIPE_ROOT/vipe_results"

# ViPE's default pipeline runs Video-Depth-Anything, which is a large extra
# download and VRAM cost. `no_vda` skips only that depth-refinement stage --
# pose and intrinsics, the only things Dyn-HaMR reads, are identical.
VIPE_PIPELINE="${VIPE_PIPELINE:-no_vda}"

[[ -f "$VIDEO" ]] || { echo "No such video: $VIDEO" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# Dyn-HaMR builds BMCLoss unconditionally, so these tables must exist even
# though the `bio` loss weight is 0 by default. Generated, not downloaded.
if [[ ! -f "$DYNHAMR_ROOT/_DATA/BMC/bone_len_max.npy" ]]; then
    echo "BMC tables missing; generating them first."
    "$(dirname "${BASH_SOURCE[0]}")/prepare_bmc.sh"
fi

# --- 1. camera estimation -------------------------------------------------
# ViPE names its outputs after the video's filename stem, so rgb.mp4 -> rgb.npz.
# This is why the data config's `seq` must be `rgb`.
if [[ -f "$VIPE_RESULTS/pose/rgb.npz" && -f "$VIPE_RESULTS/intrinsics/rgb.npz" ]]; then
    echo "[1/2] ViPE results already present, skipping."
else
    echo "[1/2] Running ViPE ($VIPE_PIPELINE) on $VIDEO"
    # Run from VIPE_ROOT: vipe resolves its hydra configs relative to cwd.
    ( cd "$VIPE_ROOT" && vipe infer "$VIDEO" --output "$VIPE_RESULTS" --pipeline "$VIPE_PIPELINE" )
fi

# --- 2. frames + HaMeR + cameras + optimization ---------------------------
# run_opt.py drives all remaining stages itself (data/dataset.py's
# check_data_sources), reading the ViPE npz files written above.
#
# exp_name=. and data.type/split overrides collapse hydra's dated
# <log_root>/<type>-<split>/<date>/<name> tree down to <OUT_DIR>/<name>, so
# reruns overwrite in place instead of accumulating one dir per day.
echo "[2/2] Running Dyn-HaMR optimization -> $OUT_DIR"
cd "$DYNHAMR_ROOT/dyn-hamr"
python3 run_opt.py \
    data=video_vipe_egoexo \
    data.root="$RECORDING" \
    data.vipe_dir="$VIPE_RESULTS" \
    log_root="$OUT_DIR" \
    log_dir="$OUT_DIR" \
    exp_name=. \
    run_opt=True \
    run_vis=True \
    is_static=False \
    "${@:2}"

echo
echo "Done. Results under $OUT_DIR"
