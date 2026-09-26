# syntax=m.daocloud.io/docker.io/docker/dockerfile:1

# =====================================================================
# ComfyUI on AMD ROCm 10.0 / Python 3.13
#
# 基础镜像 = ROCm 10.0 运行时 + Ubuntu 24.04 + Python 3.13 + PyTorch 2.13.0
# (PyTorch 为 ROCm 官方构建，已预装，无需再编译/安装 torch)
#
# 追加启动参数:  -e CLI_ARGS="--lowvram --reserve-vram 2"
# =====================================================================

# ---------------------------------------------------------------------
# 1) 基础镜像：ROCm 10.0 + Python 3.13 + PyTorch(ROCm 构建)
#    标签格式: rocm{版本}_ubuntu{版本}_py{python版本}_pytorch_release_{torch版本}
# ---------------------------------------------------------------------
FROM rocm/pytorch:rocm10.0_ubuntu24.04_py3.13_pytorch_release_2.13.0

# ---------------------------------------------------------------------
# 2) 版本参数。固定到 release tag 保证镜像可复现；
#    想跟踪最新代码可 --build-arg COMFYUI_VERSION=main
# ---------------------------------------------------------------------
ARG COMFYUI_VERSION=v0.37.4
ARG MANAGER_BRANCH=main

# ---------------------------------------------------------------------
# 3) ComfyUI 工作目录。main.py 假定 models/、output/、input/、
#    custom_nodes/ 等目录位于代码同级，所以全部收拢在 /opt/ComfyUI 下
# ---------------------------------------------------------------------
WORKDIR /opt/ComfyUI

# ---------------------------------------------------------------------
# 4) 基础工具：
#    git      克隆代码/节点
#    ffmpeg   视频类自定义节点（VideoHelperSuite 等）的硬依赖
#    aria2    ComfyUI 的 aria2 下载节点使用
#    cmake/ninja-build  编译 C/C++ 扩展类节点时的构建工具
#    fonts-noto-cjk     CJK 文字渲染
# ---------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt \
    DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git ffmpeg aria2 cmake ninja-build fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------
# 5) 克隆 ComfyUI 源码。
#    先克隆到 /tmp 再复制：git clone 的目标目录必须为空，
#    而 WORKDIR 已创建了 /opt/ComfyUI。
#    --depth 1 只取最新一次提交，下载快、镜像小
# ---------------------------------------------------------------------
RUN git clone --depth 1 --branch ${COMFYUI_VERSION} \
        https://github.com/comfy-org/ComfyUI.git /tmp/comfyui-src \
    && cp -a /tmp/comfyui-src/. /opt/ComfyUI/ \
    && rm -rf /tmp/comfyui-src

# ---------------------------------------------------------------------
# 6) 预装 ComfyUI-Manager（节点管理器，绝大多数场景都需要）
# ---------------------------------------------------------------------
RUN git clone --depth 1 --branch ${MANAGER_BRANCH} \
        https://github.com/Comfy-Org/ComfyUI-Manager.git \
        /opt/bundled/ComfyUI-Manager

# ---------------------------------------------------------------------
# 7) 关键防御：把基础镜像里已装好的 ROCm 版 torch/torchvision
#    版本导出成 constraints 文件，之后所有 pip install 都带 -c，
#    防止任何依赖解析把 torch 换成 PyPI 的 CUDA 版（症状：
#    hipError、静默回退 CPU）。比"依赖 requirements.txt 恰好不锁
#    torch 版本"这种被动做法可靠
# ---------------------------------------------------------------------
RUN pip list --format=freeze \
    | awk -F== 'BEGIN{want["torch"]=1;want["torchvision"]=1;want["torchaudio"]=1} $1 in want{print $1 "==" $2}' \
    > /opt/ComfyUI/constraints.txt \
    && cat /opt/ComfyUI/constraints.txt

# ---------------------------------------------------------------------
# 8) 安装 ComfyUI 与 Manager 的 Python 依赖。
#    --mount=type=cache 把 pip 下载缓存留在构建层外，
#    反复重建时不必重复下载几百 MB 的依赖
# ---------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -c /opt/ComfyUI/constraints.txt -r requirements.txt \
    && pip install -c /opt/ComfyUI/constraints.txt \
        -r /opt/bundled/ComfyUI-Manager/requirements.txt

# 关键步骤：把 models 目录备份到镜像内的其他位置
RUN cp -a /opt/ComfyUI/models /opt/ComfyUI/models.default

# ---------------------------------------------------------------------
# 9) 启动入口：固定核心参数，允许通过 CLI_ARGS 环境变量追加
#    （docker run -e CLI_ARGS="--lowvram" 即可，不用改镜像）
# ---------------------------------------------------------------------
COPY entrypoint.sh /opt/ComfyUI/entrypoint.sh
RUN chmod +x /opt/ComfyUI/entrypoint.sh

# ---------------------------------------------------------------------
# 10) 声明数据目录。运行时用 -v 挂载宿主机目录进来，
#     模型、产出图、自定义节点在容器删除后依然保留
# ---------------------------------------------------------------------
VOLUME ["/opt/ComfyUI/models", "/opt/ComfyUI/output", "/opt/ComfyUI/input", "/opt/ComfyUI/custom_nodes"]

# ---------------------------------------------------------------------
# 11) 声明服务端口（文档性质，实际生效靠 docker run -p）
# ---------------------------------------------------------------------
EXPOSE 8188

# ---------------------------------------------------------------------
# 12) 启动命令
# ---------------------------------------------------------------------
ENV CLI_ARGS=""
CMD ["/opt/ComfyUI/entrypoint.sh"]
