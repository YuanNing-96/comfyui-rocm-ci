#!/bin/bash
# ComfyUI 启动入口
#
# 追加启动参数:  docker run -e CLI_ARGS="--lowvram --reserve-vram 2" ...
# 可选启动前钩子: 挂载一个含 pre-start.sh 的目录
#   docker run -v $PWD/user-scripts:/opt/ComfyUI/user-scripts ...
#   pre-start.sh 里可设代理、下载模型、自检 GPU 等，
#   用 source 执行，因此其中 export 的环境变量对 ComfyUI 进程生效
set -e

echo "########################################"

# 可选的启动前脚本（存在才执行；失败则中止启动，便于暴露问题）
if [ -f /opt/ComfyUI/user-scripts/pre-start.sh ]; then
    echo "[INFO] Running pre-start script..."
    source /opt/ComfyUI/user-scripts/pre-start.sh
fi

# .pyc 字节码缓存统一写到非挂载目录，避免 __pycache__
# 混进宿主机挂载的 models/、custom_nodes/ 等目录
export PYTHONPYCACHEPREFIX="/root/.cache/pycache"

# 首次启动：把镜像自带的 Manager 拷进宿主机挂载的 custom_nodes
if [ ! -d /opt/ComfyUI/custom_nodes/ComfyUI-Manager ]; then
    mkdir -p /opt/ComfyUI/custom_nodes
    cp -a /opt/bundled/ComfyUI-Manager /opt/ComfyUI/custom_nodes/
    echo "[INFO] Installed bundled ComfyUI-Manager into custom_nodes"
fi

echo "[INFO] Starting ComfyUI..."
echo "########################################"

cd /opt/ComfyUI
exec python main.py --listen 0.0.0.0 --port 8188 ${CLI_ARGS}
