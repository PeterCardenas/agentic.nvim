# Use minimal Ubuntu base
FROM ubuntu:noble

# Tool versions matching PR check workflow
ENV EMMYLUA_VERSION=0.22.0 \
  STYLUA_VERSION=2.3.1 \
  SELENE_VERSION=0.30.0 \
  NVIM_VERSION=0.11.5 \
  DEBIAN_FRONTEND=noninteractive

# Install minimal dependencies
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  unzip \
  git \
  lua5.1 && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Setup directories
RUN mkdir -p /opt/nvim /opt/emmylua /usr/local/bin

# Install Neovim (detect architecture)
RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "aarch64" ]; then NVIM_ARCH="linux-arm64"; else NVIM_ARCH="linux-x86_64"; fi && \
  curl -sL "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-${NVIM_ARCH}.tar.gz" | \
  tar xzf - --strip-components=1 -C /opt/nvim && \
  ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim

# Install EmmyLua check (detect architecture)
RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "aarch64" ]; then EMMYLUA_ARCH="linux-arm64-glibc.2.17"; else EMMYLUA_ARCH="linux-x64-glibc.2.17"; fi && \
  curl -sL "https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases/download/${EMMYLUA_VERSION}/emmylua_check-${EMMYLUA_ARCH}.tar.gz" | \
  tar xzf - -C /opt/emmylua && \
  ln -sf /opt/emmylua/emmylua_check /usr/local/bin/emmylua_check

# Install StyLua (detect architecture)
RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "aarch64" ]; then STYLUA_ARCH="linux-aarch64"; else STYLUA_ARCH="linux-x86_64"; fi && \
  curl -sL "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-${STYLUA_ARCH}.zip" -o stylua.zip && \
  unzip -q stylua.zip -d /usr/local/bin/ && \
  chmod +x /usr/local/bin/stylua && \
  rm stylua.zip

# Install Selene (detect architecture)
RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "aarch64" ]; then SELENE_ARCH="linux-aarch64"; else SELENE_ARCH="linux-x86_64"; fi && \
  curl -sL "https://github.com/Kampfkarren/selene/releases/download/${SELENE_VERSION}/selene-${SELENE_VERSION}-${SELENE_ARCH}.zip" -o selene.zip && \
  unzip -q selene.zip -d /usr/local/bin/ && \
  chmod +x /usr/local/bin/selene && \
  rm selene.zip

WORKDIR /workspace/repro

CMD ["/bin/bash"]
