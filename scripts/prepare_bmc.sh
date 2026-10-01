#!/usr/bin/env bash
# Generate Dyn-HaMR's biomechanical-constraint (BMC) tables.
#
#   scripts/prepare_bmc.sh
#
# These 7 .npy files encode anatomical limits on hand poses -- bone lengths,
# root-bone curvature/angular distance, and per-joint angle convex hulls --
# used by dyn-hamr/optim/bio_loss.py's BMCLoss. They are NOT downloadable:
# upstream expects you to compute them from pooled 3D joint data, which is
# what this script does, via github.com/MengHao666/Hand-BMC-pytorch.
#
# BMCLoss is constructed unconditionally in optim/losses.py even though the
# `bio` loss weight defaults to 0, so these files must exist for ANY run --
# not just ones with biomechanical constraints enabled.
set -euo pipefail

DYNHAMR_ROOT="/workspace/egoexo/external/Dyn-HaMR"
DEST="$DYNHAMR_ROOT/_DATA/BMC"
WORK="${BMC_WORKDIR:-/tmp/hand-bmc-build}"

FILES=(bone_len_max bone_len_min curvatures_max curvatures_min PHI_max PHI_min CONVEX_HULLS)

# Already installed?
missing=0
for f in "${FILES[@]}"; do [[ -f "$DEST/$f.npy" ]] || missing=1; done
if [[ $missing -eq 0 ]]; then
    echo "BMC tables already present in $DEST"; exit 0
fi

command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
python3 -c "import rdp" 2>/dev/null || pip install --no-cache-dir rdp

mkdir -p "$WORK"
cd "$WORK"

# --- 1. source repo -------------------------------------------------------
if [[ ! -d Hand-BMC-pytorch ]]; then
    git clone --depth 1 https://github.com/MengHao666/Hand-BMC-pytorch.git
fi
cd Hand-BMC-pytorch

# numpy>=1.24 will not infer a ragged array, and the 15 convex hulls have
# differing vertex counts. dtype=object restores the pre-1.24 behaviour and
# matches bio_loss.py's `allow_pickle=True` load.
if ! grep -q "dtype=object" calculate_convex_hull.py; then
    sed -i 's/^    all_del_hulls = np\.array(all_del_hulls)$/    all_del_hulls = np.array(all_del_hulls, dtype=object)/' \
        calculate_convex_hull.py
fi

# --- 2. pooled 3D joint data ---------------------------------------------
# ~91 MB: joint locations from the RHD, GANerated, STB and FreiHAND datasets.
# Each is under its own license -- see the Hand-BMC-pytorch README.
if [[ ! -f joints/rhd_train.npy ]]; then
    gdown "https://drive.google.com/uc?id=1_wV8QjmsVCMBEBhm56gFA2XTyU8VEHzk" -O joints.zip
    unzip -q -o joints.zip
fi

# --- 3. bone lengths, curvatures, PHI, joint angles -----------------------
# Writes 6 limit files plus joint_angles.npy, the input to step 4.
echo "Calculating bone length / curvature / PHI limits (a few minutes)..."
MPLBACKEND=Agg python3 calculate_bmc.py

# --- 4. joint-angle convex hulls -----------------------------------------
# `visualize` defaults to True and is a store_true flag, so there is no CLI
# way to disable the (GUI-requiring, purely diagnostic) plots. Call main()
# directly with visualize off; every numeric default is upstream's.
echo "Calculating joint-angle convex hulls..."
MPLBACKEND=Agg python3 -c "
import argparse, calculate_convex_hull as m
m.main(argparse.Namespace(path='BMC', visualize=False,
                          epsilon=5e-4, ratio=0.9995, delta=0.0005))
"

# --- 5. install -----------------------------------------------------------
# joint_angles.npy (~86 MB) is an intermediate for step 4; BMCLoss never
# reads it, so it stays in the work dir.
mkdir -p "$DEST"
for f in "${FILES[@]}"; do cp "BMC/$f.npy" "$DEST/$f.npy"; done

echo
echo "Installed ${#FILES[@]} BMC tables into $DEST"
ls -la "$DEST"
