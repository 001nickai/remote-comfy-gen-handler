#!/bin/bash
set -euo pipefail

COMFYUI_DIR="/ComfyUI"
COMFYUI_PORT=8188
RUNTIME_DIR="$(cd "$(dirname "$0")" && pwd)"
COMFY_LOG="/tmp/comfyui_startup.log"

# Stamp the runtime commit at every boot so we can tell from the worker log
# which SHA is actually running. Critical when diagnosing FlashBoot snapshots
# vs true cold starts (per bead 6i0).
RUNTIME_SHA="$(git -C "$RUNTIME_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
RUNTIME_SUBJ="$(git -C "$RUNTIME_DIR" log -1 --pretty=%s 2>/dev/null || echo '?')"
echo "[start] runtime commit ${RUNTIME_SHA}: ${RUNTIME_SUBJ}"
export RUNTIME_COMMIT="${RUNTIME_SHA}: ${RUNTIME_SUBJ}"

echo "[start] Booting ComfyUI from $COMFYUI_DIR (baked in image)..."

# Verify ComfyUI exists
if [ ! -f "$COMFYUI_DIR/main.py" ]; then
    echo "[start] ERROR: ComfyUI not found at $COMFYUI_DIR"
    exit 1
fi

# --- Force ComfyUI-Manager offline mode (skip remote fetches, security scan, alembic) ---
MANAGER_CONFIG_DIR="$COMFYUI_DIR/user/__manager"
mkdir -p "$MANAGER_CONFIG_DIR"
if [ ! -f "$MANAGER_CONFIG_DIR/config.ini" ] || ! grep -q "network_mode = offline" "$MANAGER_CONFIG_DIR/config.ini" 2>/dev/null; then
    cat > "$MANAGER_CONFIG_DIR/config.ini" <<'MGREOF'
[default]
network_mode = offline
security_level = normal
MGREOF
    echo "[start] Set ComfyUI-Manager to offline mode"
fi

# Build extra model paths flag — models live on the network volume, not in the image
EXTRA_PATHS_FLAG=""
if [ -f "$COMFYUI_DIR/extra_model_paths.yaml" ]; then
    # Patch in any missing model types without rebuilding the Docker image
    if ! grep -q "detection:" "$COMFYUI_DIR/extra_model_paths.yaml"; then
        sed -i '/^    vae:/i\    detection: detection' "$COMFYUI_DIR/extra_model_paths.yaml"
        echo "[start] Patched extra_model_paths.yaml with detection"
    fi
    if ! grep -q "model_patches:" "$COMFYUI_DIR/extra_model_paths.yaml"; then
        sed -i '/^    vae:/i\    model_patches: model_patches' "$COMFYUI_DIR/extra_model_paths.yaml"
        echo "[start] Patched extra_model_paths.yaml with model_patches"
    fi
    EXTRA_PATHS_FLAG="--extra-model-paths-config $COMFYUI_DIR/extra_model_paths.yaml"
    echo "[start] Using extra_model_paths.yaml for network volume models"
fi

# --- Hotpatch kijai/ComfyUI-WanAnimatePreprocess for ONNX dropdown bug (issue #32) ---
# folder_paths caches the detection folder's filename list under the default
# extensions (no .onnx) when ANY earlier-loading node calls
# get_filename_list("detection") before this node registers .onnx. Patch the
# node to add .onnx and invalidate the cache, idempotently.
WANIMATE_NODES="$COMFYUI_DIR/custom_nodes/ComfyUI-WanAnimatePreprocess/nodes.py"
if [ -f "$WANIMATE_NODES" ] && ! grep -q "filename_list_cache" "$WANIMATE_NODES"; then
    python3 - "$WANIMATE_NODES" <<'PYEOF' && echo "[start] Hotpatched WanAnimatePreprocess for ONNX dropdown bug"
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
trigger = 'folder_paths.add_model_folder_path("detection", os.path.join(folder_paths.models_dir, "detection"))'
patch = '''
# --- onnx-dropdown hotpatch (kijai issue #32): register .onnx, invalidate cache ---
if "detection" in folder_paths.folder_names_and_paths:
    _paths, _exts = folder_paths.folder_names_and_paths["detection"]
    folder_paths.folder_names_and_paths["detection"] = (_paths, set(_exts) | {".onnx"})
    if hasattr(folder_paths, "filename_list_cache") and "detection" in folder_paths.filename_list_cache:
        del folder_paths.filename_list_cache["detection"]
    if hasattr(folder_paths, "cache_helper"):
        folder_paths.cache_helper.clear()
'''
if trigger in src and "filename_list_cache" not in src:
    p.write_text(src.replace(trigger, trigger + patch))
PYEOF
fi

# --- Stage curated custom nodes from the network volume (ALLOWLIST ONLY) ---
# Promote nodes from the persistent pod to serverless without a blanket sync.
# Two opt-in sources, both honored; the pod's full custom_nodes dir is NEVER
# blanket-linked. Baked image nodes are never clobbered. Removing a node from
# the folder/manifest un-stages it on the next cold worker (/ComfyUI is
# ephemeral per worker). Normal published nodes still come via Manager-registry
# auto-install below; this is for pinned/unpublished/promoted nodes.
#   1) snapshot folder:  $VOLUME_ROOT/ComfyUI/custom_nodes_serverless/<node>/
#   2) manifest:         $VOLUME_ROOT/ComfyUI/serverless_custom_nodes.json
#        {"nodes": ["NodeA", {"name": "NodeB", "commit": "<sha>"}]}
#      names resolve from the snapshot folder first, else the pod tree.
VOLUME_ROOT="$(dirname "$RUNTIME_DIR")"
STAGE_DIR="$VOLUME_ROOT/ComfyUI/custom_nodes_serverless"
STAGE_MANIFEST="$VOLUME_ROOT/ComfyUI/serverless_custom_nodes.json"
POD_NODES="$VOLUME_ROOT/runpod-slim/ComfyUI/custom_nodes"
TARGET_NODES="$COMFYUI_DIR/custom_nodes"
STAGED_LINKED=0; STAGED_SKIPPED=0; STAGED_MISSING=0

stage_one() {  # $1=node name  $2=pinned commit (optional)
    local name="$1" pin="${2:-}" src="" sha=""
    if   [ -d "$STAGE_DIR/$name" ]; then src="$STAGE_DIR/$name"
    elif [ -d "$POD_NODES/$name" ]; then src="$POD_NODES/$name"
    else
        echo "[stage] MISSING $name (looked in $STAGE_DIR and $POD_NODES)"
        STAGED_MISSING=$((STAGED_MISSING+1)); return 0
    fi
    if [ -e "$TARGET_NODES/$name" ] && [ ! -L "$TARGET_NODES/$name" ]; then
        echo "[stage] SKIP (baked in image) $name"
        STAGED_SKIPPED=$((STAGED_SKIPPED+1)); return 0
    fi
    if [ -n "$pin" ]; then
        if git -C "$src" cat-file -e "${pin}^{commit}" 2>/dev/null; then
            git -C "$src" checkout -q "$pin" 2>/dev/null || true
        else
            echo "[stage] SKIP $name — pinned commit $pin not found in $src"
            STAGED_SKIPPED=$((STAGED_SKIPPED+1)); return 0
        fi
    fi
    sha="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo nogit)"
    ln -sfn "$src" "$TARGET_NODES/$name"
    echo "[stage] LINKED $name -> $src @ $sha${pin:+ (pinned $pin)}"
    STAGED_LINKED=$((STAGED_LINKED+1))
    if [ -f "$src/requirements.txt" ]; then
        pip install -q -r "$src/requirements.txt" 2>/dev/null \
            && echo "[stage]   deps installed for $name" \
            || echo "[stage]   WARNING deps install failed for $name"
    fi
}

if [ -d "$STAGE_DIR" ] || [ -f "$STAGE_MANIFEST" ] || [ -n "${SERVERLESS_EXTRA_NODES:-}" ]; then
    mkdir -p "$TARGET_NODES"
    echo "[stage] Staging curated serverless custom nodes (allowlist)..."
    if [ -d "$STAGE_DIR" ]; then
        for d in "$STAGE_DIR"/*/; do
            [ -d "$d" ] || continue
            stage_one "$(basename "$d")" ""
        done
    fi
    if [ -f "$STAGE_MANIFEST" ]; then
        MANIFEST_LINES="$(python3 - "$STAGE_MANIFEST" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("__PARSE_ERROR__\t%s" % e); sys.exit(0)
nodes = d.get("nodes", []) if isinstance(d, dict) else d
if not isinstance(nodes, list): nodes = []
for n in nodes:
    if isinstance(n, str):
        if n.strip(): print("%s\t" % n.strip())
    elif isinstance(n, dict) and n.get("name"):
        print("%s\t%s" % (n["name"].strip(), (n.get("commit") or "").strip()))
PYEOF
)"
        while IFS=$'\t' read -r mname mcommit; do
            [ -z "$mname" ] && continue
            if [ "$mname" = "__PARSE_ERROR__" ]; then
                echo "[stage] WARNING manifest parse error: $mcommit (ignoring manifest)"; continue
            fi
            [ -L "$TARGET_NODES/$mname" ] && continue   # already linked via snapshot folder
            stage_one "$mname" "$mcommit"
        done <<< "$MANIFEST_LINES"
    fi
    #   3) env allowlist: space-separated node names, set per-endpoint in the RunPod
    #      template (SERVERLESS_EXTRA_NODES). Keeps staging endpoint-scoped — the voice
    #      endpoint stages Qwen-TTS without touching the image endpoint's cold starts.
    for en in ${SERVERLESS_EXTRA_NODES:-}; do
        [ -L "$TARGET_NODES/$en" ] && continue   # already linked via folder/manifest
        stage_one "$en" ""
    done
    echo "[stage] Summary: linked=$STAGED_LINKED skipped=$STAGED_SKIPPED missing=$STAGED_MISSING"
else
    echo "[stage] No serverless node staging configured ($STAGE_DIR / $STAGE_MANIFEST absent)"
fi

# --- Qwen-TTS lane extras (only when SERVERLESS_EXTRA_NODES is set) ---
# The Qwen-TTS node reads/writes models via the BASE models dir (ephemeral in the image),
# not extra_model_paths: link its model home to the volume so the ~9GB of TTS models are
# not re-downloaded per cold worker and SaveVoice speakers persist to the shared volume.
if [ -n "${SERVERLESS_EXTRA_NODES:-}" ]; then
    for QROOT in "$VOLUME_ROOT/ComfyUI/models/qwen-tts" "$VOLUME_ROOT/runpod-slim/ComfyUI/models/qwen-tts"; do
        if [ -d "$QROOT" ]; then
            mkdir -p "$COMFYUI_DIR/models"
            ln -sfn "$QROOT" "$COMFYUI_DIR/models/qwen-tts"
            echo "[stage] qwen-tts models linked -> $QROOT"
            break
        fi
    done
    # The baked venv can carry a placeholder accelerate==0.0.1 (empty stub) that satisfies
    # pip but fails transformers' is_accelerate_available() at model load (burned on the
    # pod 2026-07-08) — force a real accelerate if needed.
    python3 - <<'PYEOF' || pip install -q --no-cache-dir "accelerate>=1.0"
import sys
try:
    import accelerate
    ok = tuple(int(x) for x in accelerate.__version__.split(".")[:2]) >= (1, 0)
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PYEOF
fi

# --- Start ComfyUI, tee output to log file for IMPORT FAILED detection ---
cd "$COMFYUI_DIR"
# Experimental performance flags (enable via EXPERIMENTAL=true env var)
PERF_FLAGS=""
if [ "${EXPERIMENTAL:-}" = "true" ]; then
    echo "[start] Experimental mode: enabling cublas_ops, flash-attention"
    # NOTE: fp8_matrix_mult causes corrupted output with Qwen Image models (ComfyUI #9190)
    # NOTE: --gpu-only removed — causes OOM on large workflows
    PERF_FLAGS="--fast cublas_ops --use-flash-attention"
fi

python3 main.py \
    --listen 0.0.0.0 \
    --port $COMFYUI_PORT \
    --disable-auto-launch \
    --disable-metadata \
    $PERF_FLAGS \
    $EXTRA_PATHS_FLAG \
    > >(tee "$COMFY_LOG") 2>&1 &

COMFYUI_PID=$!
echo "[start] ComfyUI starting (PID: $COMFYUI_PID)..."

# Wait for ComfyUI to be ready
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s "http://127.0.0.1:$COMFYUI_PORT/system_stats" > /dev/null 2>&1; then
        echo "[start] ComfyUI ready after ${WAITED}s"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo "[start] ERROR: ComfyUI failed to start within ${MAX_WAIT}s"
    kill $COMFYUI_PID 2>/dev/null || true
    exit 1
fi

# --- Fix broken custom nodes (IMPORT FAILED) ---
# Parse ComfyUI startup log for nodes that failed to import,
# reinstall their deps, and restart ComfyUI if any were fixed.
BROKEN_NODES=$(grep -o 'IMPORT FAILED.*custom_nodes/[^"]*' "$COMFY_LOG" 2>/dev/null \
    | sed 's|.*/custom_nodes/||' | sort -u || true)

if [ -n "$BROKEN_NODES" ]; then
    echo "[start] Found broken custom nodes:"
    NEEDS_RESTART=false
    CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"

    while IFS= read -r node_name; do
        req_file="$CUSTOM_NODES_DIR/$node_name/requirements.txt"
        if [ -f "$req_file" ]; then
            echo "[start]   -> $node_name: reinstalling deps..."
            pip install -q -r "$req_file" 2>/dev/null && NEEDS_RESTART=true \
                || echo "[start]   WARNING: deps install failed for $node_name"
        else
            echo "[start]   -> $node_name: no requirements.txt, skipping"
        fi
    done <<< "$BROKEN_NODES"

    if $NEEDS_RESTART; then
        echo "[start] Restarting ComfyUI to reload fixed nodes..."
        kill $COMFYUI_PID 2>/dev/null || true
        sleep 2

        cd "$COMFYUI_DIR"
        python3 main.py \
            --listen 0.0.0.0 \
            --port $COMFYUI_PORT \
            --disable-auto-launch \
            --disable-metadata \
            $PERF_FLAGS \
            $EXTRA_PATHS_FLAG \
            &
        COMFYUI_PID=$!

        WAITED=0
        while [ $WAITED -lt $MAX_WAIT ]; do
            if curl -s "http://127.0.0.1:$COMFYUI_PORT/system_stats" > /dev/null 2>&1; then
                echo "[start] ComfyUI restarted after ${WAITED}s"
                break
            fi
            sleep 2
            WAITED=$((WAITED + 2))
        done

        # Invalidate deps stamp so start_script.sh reinstalls next time
        rm -f /runpod-volume/.custom-node-deps-stamp
    fi
else
    echo "[start] All custom nodes loaded OK"
fi

# Start the RunPod worker handler
echo "[start] Starting RunPod handler..."
exec python3 "$RUNTIME_DIR/worker.py"
