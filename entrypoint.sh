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

# 仅当 PUID 和 PGID 同时提供时才做用户映射
if [ -n "${PUID}" ] && [ -n "${PGID}" ]; then
    echo "[INFO] PUID ${PUID} PGID ${PGID} inject"

    # 严格校验纯数字，防止注入
    if ! [[ "$PUID" =~ ^[0-9]+$ ]] || ! [[ "$PGID" =~ ^[0-9]+$ ]]; then
        echo "错误：PUID 和 PGID 必须是纯数字。" >&2
        exit 1
    fi

    # 创建/更新用户与组
    if ! getent group "$PGID" >/dev/null; then
        groupadd -g "$PGID" comfyui
    fi
    if ! getent passwd "$PUID" >/dev/null; then
        useradd -u "$PUID" -g "$PGID" -M -s /bin/bash comfyui
    fi

    # 仅当 APP_DIRS 非空时才执行 chown
    if [ -n "${APP_DIRS}" ]; then
        echo ">> 将对以下目录执行 chown：${APP_DIRS}"
        for d in $APP_DIRS; do
            if [ -d "$d" ]; then
                chown -R "$PUID:$PGID" "$d"
            else
                echo ">> 跳过不存在的目录：$d"
            fi
        done
    fi

    RUN_AS="gosu $PUID:$PGID"
fi


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

# 判断 models 是否为空（-A 会列出包括隐藏文件在内的所有条目）
if [ -z "$(ls -A /opt/ComfyUI/models)" ]; then
    echo "[entrypoint] /opt/ComfyUI/models 为空，从 /opt/ComfyUI/models.default 恢复默认结构..."
    cp -a /opt/ComfyUI/models.default/. /opt/ComfyUI/models/
fi

echo "[INFO] Starting ComfyUI..."
echo "########################################"

cd /opt/ComfyUI

# 启动 socat：监听 0.0.0.0:8188，转发到 127.0.0.1:8189
socat TCP-LISTEN:8188,fork,reuseaddr TCP:127.0.0.1:8189 &

exec python main.py --listen 127.0.0.1 --port 8189 ${CLI_ARGS}
