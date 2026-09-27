# syntax=m.daocloud.io/docker.io/docker/dockerfile:1

# =====================================================================
# ComfyUI on AMD ROCm 10.0 / Python 3.13
#
# 基础镜像 = ROCm 10.0 运行时 + Ubuntu 24.04 + Python 3.13 + PyTorch 2.13.0
# (PyTorch 为 ROCm 官方构建，已预装，无需再编译/安装 torch)
#
# 追加启动参数:  -e CLI_ARGS="--lowvram --reserve-vram 2"
# =====================================================================

# =====================================================================
# 构建阶段：复用与运行阶段相同的基础镜像，避免单独安装 Python 3.13
# =====================================================================
FROM m.daocloud.io/docker.io/rocm/pytorch:rocm10.0_ubuntu24.04_py3.13_pytorch_release_2.13.0 AS llama-cpp-builder

# 替换 Ubuntu apt 源
RUN sed -i 's|http://archive.ubuntu.com|https://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's|http://security.ubuntu.com|https://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/ubuntu.sources

# 添加 ROCm 10.0 APT 源并安装开发包
RUN apt-get update && apt-get install -y --no-install-recommends curl gnupg2 \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://stable.repo.amd.com/rocm/core/packages/ubuntu2404 stable main" > /etc/apt/sources.list.d/rocm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        amdrocm-core-dev10.0 \
        amdrocm-blas-dev \
    && rm -rf /var/lib/apt/lists/*

# 配置 pip 国内源
RUN pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple \
    && pip config set global.trusted-host pypi.tuna.tsinghua.edu.cn \
    && pip config set global.extra-index-url https://pypi.org/simple

# 在构建阶段，安装 patchelf 前执行
RUN add-apt-repository universe && apt-get update \
    && apt-get install -y --no-install-recommends patchelf

# 2) 把构建后端提前装进 venv
RUN /opt/venv/bin/pip install --no-cache-dir \
    scikit-build-core cmake ninja

# 编译并安装到 site-packages（关键：用 install，不是 wheel）
# 编译并安装到 site-packages
RUN CMAKE_ARGS="-DGGML_HIP=on \
    -DAMDGPU_TARGETS=gfx1100 \
    -DCMAKE_HIP_COMPILER_ROCM_ROOT=/opt/rocm \
    -DCMAKE_C_COMPILER=/opt/rocm/llvm/bin/clang \
    -DCMAKE_CXX_COMPILER=/opt/rocm/llvm/bin/clang++ \
    -DCMAKE_PREFIX_PATH=/opt/rocm \
    -DGGML_NATIVE=OFF" \
    FORCE_CMAKE=1 \
    HIP_PATH=/opt/rocm \
    CXX=/opt/rocm/bin/hipcc \
    bash -c '/opt/venv/bin/pip install -v --no-build-isolation --no-cache-dir llama-cpp-python \
        > /tmp/llama-build.log 2>&1 \
        || (echo "===== BUILD FAILED, last 300 lines =====" && tail -n 300 /tmp/llama-build.log && exit 1)'

# 断言 HIP 后端真的编出来了
RUN ls /opt/venv/lib/python3.13/site-packages/llama_cpp/lib/ | grep -q "ggml-hip" \
    || (echo "ERROR: HIP backend not built" && exit 1)

# 显式复制 HIP 核心库到 llama_cpp/lib/
RUN SITE_PACKAGES=$(/opt/venv/bin/python -c "import sysconfig; print(sysconfig.get_path('purelib'))") && \
    DEST="$SITE_PACKAGES/llama_cpp/lib" && \
    for d in \
        /opt/venv/lib/python3.13/site-packages/_rocm_sdk_libraries \
        /opt/venv/lib/python3.13/site-packages/_rocm_sdk_core ; do \
        if [ -d "$d" ] ; then \
            echo "===== Copying from $d =====" && \
            find "$d" -name "*.so*" -type f -exec cp -L --update=none {} "$DEST/" \; 2>/dev/null || true ; \
            find "$d" -name "*.so*" -type l -exec cp -L --update=none {} "$DEST/" \; 2>/dev/null || true ; \
        fi \
    done && \
    echo "===== llama_cpp/lib after copy =====" && \
    ls "$DEST/" | grep -E "hipblas|amdhip|libomp" || echo "WARNING: some libs missing"

# 设置 RPATH 为 $ORIGIN
RUN SITE_PACKAGES=$(/opt/venv/bin/python -c "import sysconfig; print(sysconfig.get_path('purelib'))") && \
    find "$SITE_PACKAGES/llama_cpp/lib" -name "*.so*" \
    -exec patchelf --set-rpath '$ORIGIN' {} \;

RUN /opt/venv/bin/pip install --no-cache-dir wheel \
    && SITE_PACKAGES=$(/opt/venv/bin/python -c "import sysconfig; print(sysconfig.get_path('purelib'))") \
    && mkdir -p /tmp/wheel_stage \
    && cp -a "$SITE_PACKAGES/llama_cpp" /tmp/wheel_stage/ \
    && cp -a "$SITE_PACKAGES"/llama_cpp_python-*.dist-info /tmp/wheel_stage/ \
    && mkdir -p /tmp/wheels \
    && /opt/venv/bin/python -m wheel pack /tmp/wheel_stage -d /tmp/wheels

# ---------------------------------------------------------------------
# 1) 基础镜像：ROCm 10.0 + Python 3.13 + PyTorch(ROCm 构建)
#    标签格式: rocm{版本}_ubuntu{版本}_py{python版本}_pytorch_release_{torch版本}
# ---------------------------------------------------------------------
FROM m.daocloud.io/docker.io/rocm/pytorch:rocm10.0_ubuntu24.04_py3.13_pytorch_release_2.13.0

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

# 替换 apt 源为清华镜像
RUN sed -i 's|http://archive.ubuntu.com|https://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's|http://security.ubuntu.com|https://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update

# 配置 pip 国内源
RUN pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple \
    && pip config set global.trusted-host pypi.tuna.tsinghua.edu.cn \
    && pip config set global.extra-index-url https://pypi.org/simple

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
        git ffmpeg aria2 cmake ninja-build fonts-noto-cjk socat \
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

# 从构建阶段复制 wheel 并安装
COPY --from=llama-cpp-builder /tmp/wheels/ /tmp/llama-wheels/
RUN pip install --no-cache-dir --find-links=/tmp/llama-wheels /tmp/llama-wheels/*.whl && rm -rf /tmp/llama-wheels

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
