#!/usr/bin/env bash
# =============================================================================
#  setup_notebook.sh — prepara um notebook Linux zerado para o stack do Carlos
# =============================================================================
#  Inspirado no padrão do setup_local.sh (pycodebr/scsi_v1), adaptado para:
#    Python + Django/FastAPI, Docker, Node, Hermes Agent, OpenCode, Tailscale
#    e o kit de configuração do servidor lemosserver.
#
#  Idempotente: pode rodar quantas vezes quiser; pula o que já existe.
#  Log completo: ~/setup_notebook.log
#
#  USO:
#    bash setup_notebook.sh
#    bash setup_notebook.sh --bundle /caminho/hermes-opencode-notebook.tar.gz
#    bash setup_notebook.sh --bundle https://host/kit.tar.gz --with-ssh
#    bash setup_notebook.sh --no-docker --yes
#
#  OPÇÕES:
#    --bundle PATH|URL  kit do Hermes/OpenCode (tgz ou diretório)
#    --with-ssh         configura chave SSH e acesso root ao lemosserver
#    --no-docker        não instala Docker
#    --skip-kit         instala só as ferramentas, sem aplicar configuração
#    --yes              não pergunta nada (usa padrões)
# =============================================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# Quando chega por 'curl ... | bash', a entrada padrão não é terminal:
# reaponta para o tty real para que as perguntas funcionem.
if [[ ! -t 0 ]]; then
  # Só reaponta se /dev/tty realmente abrir (em container/pipe pode não existir)
  if { exec 3</dev/tty; } 2>/dev/null; then
    exec <&3
    exec 3<&-
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Constantes
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
  SCRIPT_NAME="$(basename "$SCRIPT_SOURCE")"
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
else
  # veio por pipe (curl | bash) ou colado no terminal
  SCRIPT_NAME="setup_notebook.sh"
  SCRIPT_DIR="$PWD"
fi
readonly SCRIPT_NAME SCRIPT_DIR
readonly LOG_FILE="$HOME/setup_notebook.log"
readonly KIT_DIR="$HOME/hermes-kit"
readonly SERVER_TS_IP="${SERVER_TS_IP:-100.88.69.82}"
readonly SERVER_USER="${SERVER_USER:-lemosserver}"
readonly NODE_MAJOR_MIN=20

TOTAL_STEPS=9
CURRENT_STEP=0

BUNDLE_SRC=""
WITH_SSH=0
DO_DOCKER=1
SKIP_KIT=0
ASSUME_YES=0

usage() {
  if [[ -n "${SCRIPT_SOURCE:-}" && -f "${SCRIPT_SOURCE:-}" ]]; then
    sed -n '2,30p' "$SCRIPT_SOURCE" | sed 's/^# \{0,1\}//'
    return
  fi
  cat <<'TXT'
setup_notebook.sh — prepara um notebook Linux zerado para o stack do Carlos

USO:
  bash setup_notebook.sh
  bash setup_notebook.sh --bundle /caminho/hermes-opencode-notebook.tar.gz
  bash setup_notebook.sh --bundle https://host/kit.tar.gz --with-ssh
  bash setup_notebook.sh --no-docker --yes

OPÇÕES:
  --bundle PATH|URL  kit do Hermes/OpenCode (tgz ou diretório)
  --with-ssh         configura chave SSH e acesso root ao lemosserver
  --no-docker        não instala Docker
  --skip-kit         instala só as ferramentas, sem aplicar configuração
  --yes              não pergunta nada (usa padrões)
TXT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)   BUNDLE_SRC="${2:-}"; [[ -n "$BUNDLE_SRC" ]] || { echo "--bundle exige um caminho ou URL"; exit 2; }; shift 2 ;;
    --with-ssh) WITH_SSH=1; shift ;;
    --no-docker) DO_DOCKER=0; shift ;;
    --skip-kit) SKIP_KIT=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "opção desconhecida: $1 (use --help)"; exit 2 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
#  Cores e símbolos
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD="$(tput bold)";   RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"; GREY="$(tput setaf 8)"
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; GREY=""
fi

_logfile() { printf '%s %s\n' "[$(date '+%H:%M:%S')]" "$1" >>"$LOG_FILE"; }

banner() {
  echo ""
  echo "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
  printf "${BOLD}${CYAN}║${RESET} %-60s ${BOLD}${CYAN}║${RESET}\n" "$1"
  echo "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
}

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo ""
  echo "${BOLD}${BLUE}▶ ETAPA ${CURRENT_STEP}/${TOTAL_STEPS}:${RESET} ${BOLD}$1${RESET}"
  echo "${GREY}──────────────────────────────────────────────────────────────${RESET}"
  _logfile "ETAPA ${CURRENT_STEP}/${TOTAL_STEPS}: $1"
}

info()    { echo "  ${BLUE}ℹ${RESET}  $1";        _logfile "INFO  $1"; }
ok()      { echo "  ${GREEN}✔${RESET}  $1";        _logfile "OK    $1"; }
warn()    { echo "  ${YELLOW}⚠${RESET}  $1";       _logfile "WARN  $1"; }
skip()    { echo "  ${GREEN}✓${RESET}  ${GREY}$1 (já presente — pulando)${RESET}"; _logfile "SKIP  $1"; }
working() { echo "  ${CYAN}⏳${RESET} $1...";       _logfile "WORK  $1"; }

# ─────────────────────────────────────────────────────────────────────────────
#  Erros — motivo, linha, comando e como retomar
# ─────────────────────────────────────────────────────────────────────────────
on_error() {
  local exit_code=$1 line=$2 cmd=$3
  echo ""
  echo "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo "${BOLD}${RED}║  ❌ ERRO — o script parou                                    ║${RESET}"
  echo "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo "  ${RED}Etapa........:${RESET} ${CURRENT_STEP}/${TOTAL_STEPS}"
  echo "  ${RED}Linha........:${RESET} ${line}"
  echo "  ${RED}Comando......:${RESET} ${cmd}"
  echo "  ${RED}Código saída.:${RESET} ${exit_code}"
  echo ""
  echo "  ${YELLOW}O que fazer:${RESET}"
  echo "    1. Leia a mensagem acima desta caixa."
  echo "    2. Log completo: ${BOLD}${LOG_FILE}${RESET}"
  echo "    3. Rode de novo — o script é idempotente e retoma do ponto seguro."
  echo ""
  _logfile "ERRO exit=$exit_code line=$line cmd=<$cmd> step=$CURRENT_STEP/$TOTAL_STEPS"
  if [[ -e /dev/tty ]]; then
    read -r -p "  Pressione ENTER para fechar..." _ </dev/tty 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap 'on_error $? ${LINENO} "$BASH_COMMAND"' ERR

# ─────────────────────────────────────────────────────────────────────────────
#  Utilitários
# ─────────────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

persist_path() {
  local line='export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"'
  local f
  for f in "$HOME/.bashrc" "$HOME/.profile"; do
    [[ -f "$f" ]] || continue
    grep -qF '.opencode/bin' "$f" 2>/dev/null && continue
    printf '\n# Hermes/OpenCode CLIs\n%s\n' "$line" >>"$f"
  done
}

show_log_tail() {
  [[ -s "$LOG_FILE" ]] || return 0
  echo "  ${GREY}últimas linhas do log:${RESET}"
  tail -n 5 "$LOG_FILE" | sed 's/^/    /'
}

retry() {
  local max=3 attempt=1 delay=3
  while true; do
    if "$@"; then return 0; fi
    if (( attempt >= max )); then
      warn "Falhou após ${max} tentativas: $*"
      return 1
    fi
    warn "Tentativa ${attempt}/${max} falhou. Nova em ${delay}s..."
    sleep "$delay"; attempt=$((attempt + 1)); delay=$((delay * 2))
  done
}

confirm_SN() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local prompt="$1" answer
  while true; do
    read -r -p "  ${YELLOW}❓ ${prompt} [S/N]:${RESET} " answer || true
    case "$answer" in
      [Ss]|[Ss][Ii][Mm]) return 0 ;;
      [Nn]|[Nn][Aa][Oo]) return 1 ;;
      *) warn "Responda com S ou N." ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────────────────────
#  SO e gerenciador de pacotes
# ─────────────────────────────────────────────────────────────────────────────
OS=""; DISTRO=""; PKG=""; SUDO=""

detect_os() {
  case "$(uname -s)" in
    Linux) OS="linux" ;;
    Darwin) OS="macos" ;;
    *) echo "SO não suportado: $(uname -s). Este script é para Linux (ou macOS via Homebrew)."; exit 1 ;;
  esac

  if [[ "$OS" == "macos" ]]; then
    PKG="brew"
  else
    [[ -r /etc/os-release ]] && . /etc/os-release
    DISTRO="${ID:-}${ID_LIKE:+ $ID_LIKE}"
    if   have apt-get; then PKG="apt"
    elif have dnf;     then PKG="dnf"
    elif have pacman;  then PKG="pacman"
    elif have zypper;  then PKG="zypper"
    else echo "Gerenciador de pacotes não suportado (apt/dnf/pacman/zypper)."; exit 1
    fi
    if [[ "$(id -u)" -ne 0 ]]; then
      have sudo || { echo "Preciso de sudo para instalar pacotes."; exit 1; }
      SUDO="sudo"
    fi
  fi
  info "Sistema......: ${BOLD}${OS}${RESET}${DISTRO:+ (${DISTRO})}"
  info "Gerenciador..: ${BOLD}${PKG}${RESET}"
  info "Usuário......: ${BOLD}$(id -un)${RESET} ($HOME)"
}

PKG_UPDATED=0
pkg_update_once() {
  [[ "$PKG_UPDATED" -eq 1 ]] && return 0
  case "$PKG" in
    apt)
      working "Atualizando índice (apt update)"
      if ! retry $SUDO apt-get update >>"$LOG_FILE" 2>&1; then
        warn "apt update falhou — algum repositório está quebrado:"
        grep -E '^(E|W):' "$LOG_FILE" 2>/dev/null | tail -4 | sed 's/^/    /'
        info "sigo usando os índices que já existem; instalações por apt podem falhar"
      fi
      ;;
    dnf)    : ;;
    pacman) working "Sincronizando (pacman -Sy)"; retry $SUDO pacman -Sy --noconfirm >>"$LOG_FILE" 2>&1 || warn "pacman -Sy falhou" ;;
    zypper) working "Atualizando repositórios"; retry $SUDO zypper --non-interactive refresh >>"$LOG_FILE" 2>&1 || warn "zypper refresh falhou" ;;
    brew)   : ;;
  esac
  PKG_UPDATED=1
}

pkg_install() {
  local pkg="$1"
  pkg_update_once
  case "$PKG" in
    brew)   retry brew install "$pkg" >>"$LOG_FILE" 2>&1 || return 1 ;;
    apt)    retry $SUDO apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 || return 1 ;;
    dnf)    retry $SUDO dnf install -y "$pkg" >>"$LOG_FILE" 2>&1 || return 1 ;;
    pacman) retry $SUDO pacman -S --noconfirm "$pkg" >>"$LOG_FILE" 2>&1 || return 1 ;;
    zypper) retry $SUDO zypper --non-interactive install -y "$pkg" >>"$LOG_FILE" 2>&1 || return 1 ;;
  esac
}

# =============================================================================
#  ETAPA 0 — boas-vindas
# =============================================================================
: >"$LOG_FILE"
banner "SETUP DO NOTEBOOK — Hermes + OpenCode + stack"
echo "  Prepara a máquina do zero: Python, Node, Docker, Hermes, OpenCode,"
echo "  Tailscale e o kit de configuração do servidor."
echo "  ${BOLD}Idempotente${RESET}: pode rodar quantas vezes quiser."
echo "  Log: ${GREY}${LOG_FILE}${RESET}"

step "Detectando sistema e instalando ferramentas base"
detect_os

persist_path
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

if [[ -n "$SUDO" ]]; then
  info "Autenticando sudo (pede a senha uma única vez)"
  if ! $SUDO -v; then
    warn "sudo não autenticado — as instalações de sistema vão falhar"
  fi
fi

BASE_PKGS=(git curl ca-certificates unzip rsync)
[[ "$PKG" == "apt" ]] && BASE_PKGS+=(build-essential software-properties-common)

for pkg in "${BASE_PKGS[@]}"; do
  case "$pkg" in
    git)    have git    && { skip "git"; continue; } ;;
    curl)   have curl   && { skip "curl"; continue; } ;;
    rsync)  have rsync  && { skip "rsync"; continue; } ;;
    unzip)  have unzip  && { skip "unzip"; continue; } ;;
  esac
  working "Instalando $pkg"
  pkg_install "$pkg" || warn "não consegui instalar $pkg"
done

for pkg in ripgrep ffmpeg; do
  if have "$pkg"; then skip "$pkg"; else
    working "Instalando $pkg"; pkg_install "$pkg" || warn "$pkg indisponível no repositório"
  fi
done
ok "Ferramentas base prontas"

# =============================================================================
#  ETAPA 1 — Python 3.12+ com venv
# =============================================================================
step "Python 3.12+ e venv"

python_ok() {
  local py="$1"
  "$py" - <<'PY' >/dev/null 2>&1
import sys
assert sys.version_info >= (3, 12), sys.version
PY
}

PYTHON_BIN=""
for candidate in python3.13 python3.12 python3; do
  if have "$candidate" && python_ok "$candidate"; then PYTHON_BIN="$candidate"; break; fi
done

if [[ -n "$PYTHON_BIN" ]]; then
  skip "$PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"
else
  working "Instalando Python 3.12"
  [[ "$PKG" == "apt" ]] && pkg_install python3.12 || pkg_install python3
  PYTHON_BIN="python3"
  python_ok "$PYTHON_BIN" || warn "Python encontrado é anterior ao 3.12; Django 5+ pode reclamar."
fi

if [[ "$PKG" == "apt" ]]; then
  for p in python3-venv python3-pip python3-dev; do
    dpkg -s "$p" >/dev/null 2>&1 && skip "$p" || { working "Instalando $p"; pkg_install "$p" || warn "falhou: $p"; }
  done
fi

if "$PYTHON_BIN" -m venv --help >/dev/null 2>&1; then
  ok "venv funcional"
else
  warn "módulo venv indisponível; instale python3-venv"
fi

# =============================================================================
#  ETAPA 2 — Node.js LTS
# =============================================================================
step "Node.js LTS e npm"

install_node_tarball() {
  local ver="v22.23.4" arch
  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) warn "arquitetura $(uname -m) sem tarball oficial do Node"; return 1 ;;
  esac
  mkdir -p "$HOME/.local/opt/node" "$HOME/.local/bin"
  if retry curl -fsSL "https://nodejs.org/dist/$ver/node-$ver-linux-$arch.tar.xz" \
       | tar -xJ --strip-components=1 -C "$HOME/.local/opt/node" >>"$LOG_FILE" 2>&1; then
    ln -sf "$HOME/.local/opt/node/bin/node" "$HOME/.local/bin/node"
    ln -sf "$HOME/.local/opt/node/bin/npm"  "$HOME/.local/bin/npm"
    ln -sf "$HOME/.local/opt/node/bin/npx"  "$HOME/.local/bin/npx"
    export PATH="$HOME/.local/bin:$PATH"
    return 0
  fi
  return 1
}

node_version_ok() {
  have node || return 1
  local major
  major="$(node -v | sed 's/^v//; s/\..*//')"
  [[ "$major" -ge "$NODE_MAJOR_MIN" ]]
}

if node_version_ok; then
  skip "node $(node -v) / npm $(npm -v 2>/dev/null || echo '?')"
else
  working "Instalando Node.js ${NODE_MAJOR_MIN}+"
  if [[ "$PKG" == "apt" ]]; then
    if [[ -n "$SUDO" ]]; then
      retry bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -' >>"$LOG_FILE" 2>&1 \
        || warn "repositório NodeSource falhou"
    else
      retry bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -' >>"$LOG_FILE" 2>&1 \
        || warn "repositório NodeSource falhou"
    fi
    pkg_install nodejs || { warn "não consegui instalar nodejs"; show_log_tail; }
  else
    pkg_install nodejs
  fi
  if ! node_version_ok; then
    warn "Node do sistema é antigo; instalando tarball oficial"
    install_node_tarball || true
  fi
  node_version_ok && ok "node $(node -v)" || warn "Node antigo; alguns CLIs podem exigir versão maior"
fi

# =============================================================================
#  ETAPA 3 — Docker + Compose
# =============================================================================
step "Docker e Docker Compose"

if [[ "$DO_DOCKER" -eq 0 ]]; then
  info "Pulado por --no-docker"
elif have docker; then
  skip "docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
else
  working "Instalando Docker (script oficial)"
  retry bash -c 'curl -fsSL https://get.docker.com | sh' >>"$LOG_FILE" 2>&1 || warn "instalação do Docker falhou"
  have docker && ok "Docker instalado" || warn "Docker não instalado"
fi

if have docker; then
  if id -nG "$(id -un)" | grep -qw docker; then
    skip "grupo docker"
  else
    working "Adicionando $(id -un) ao grupo docker"
    $SUDO usermod -aG docker "$(id -un)" && ok "grupo docker (vale no próximo login)" || warn "usermod falhou"
  fi
  docker compose version >/dev/null 2>&1 && ok "docker compose disponível" || warn "plugin compose ausente"
fi

# =============================================================================
#  ETAPA 4 — Hermes Agent
# =============================================================================
step "Hermes Agent"

export PATH="$HOME/.local/bin:$PATH"

if have hermes; then
  skip "hermes $(hermes --version 2>/dev/null | head -1)"
else
  working "Instalando Hermes (instalador oficial)"
  retry bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' >>"$LOG_FILE" 2>&1 \
    || warn "instalador do Hermes falhou"
  have hermes && ok "hermes $(hermes --version 2>/dev/null | head -1)" || warn "hermes não encontrado no PATH"
fi

# =============================================================================
#  ETAPA 5 — OpenCode
# =============================================================================
step "OpenCode"

export PATH="$HOME/.opencode/bin:$PATH"

if have opencode; then
  skip "opencode $(opencode --version 2>/dev/null | head -1)"
else
  working "Instalando OpenCode (instalador oficial)"
  retry bash -c 'curl -fsSL https://opencode.ai/install | bash' >>"$LOG_FILE" 2>&1 \
    || warn "instalador do OpenCode falhou"
  have opencode && ok "opencode $(opencode --version 2>/dev/null | head -1)" || warn "opencode não encontrado no PATH"
fi

# =============================================================================
#  ETAPA 6 — kit de configuração
# =============================================================================
step "Kit de configuração (Hermes + OpenCode do servidor)"

find_bundle() {
  local candidates=()
  [[ -n "$BUNDLE_SRC" ]] && candidates+=("$BUNDLE_SRC")
  candidates+=(
    "$SCRIPT_DIR/hermes-opencode-notebook.tar.gz"
    "$KIT_DIR/hermes-opencode-notebook.tar.gz"
    "$HOME/hermes-opencode-notebook.tar.gz"
    "$HOME/Área de trabalho/Hermes/hermes-opencode-notebook.tar.gz"
    "$HOME/Área de trabalho/hermes-opencode-notebook.tar.gz"
    "$HOME/Desktop/Hermes/hermes-opencode-notebook.tar.gz"
    "$HOME/Downloads/hermes-opencode-notebook.tar.gz"
  )
  # pendrives montados
  local m
  for m in /media/*/*/Hermes*/hermes-opencode-notebook.tar.gz /run/media/*/*/Hermes*/hermes-opencode-notebook.tar.gz; do
    [[ -e "$m" ]] && candidates+=("$m")
  done
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -e "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

if [[ "$SKIP_KIT" -eq 1 ]]; then
  info "Pulado por --skip-kit"
else
  KIT_SRC="$(find_bundle || true)"

  # aceita a pasta no --bundle e procura o .tar.gz dentro dela
  if [[ -n "$KIT_SRC" && -d "$KIT_SRC" ]]; then
    KIT_SRC="$(find "$KIT_SRC" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | head -1)"
  fi

  if [[ -z "$KIT_SRC" ]]; then
    warn "kit não encontrado (procurei no pendrive e em $KIT_DIR)"
    info "Rode de novo com: --bundle /caminho/hermes-opencode-notebook.tar.gz"
  else
    ok "kit encontrado: $KIT_SRC"
    mkdir -p "$KIT_DIR"

    case "$KIT_SRC" in
      http://*|https://*)
        working "Baixando o kit"
        retry curl -fL "$KIT_SRC" -o "$KIT_DIR/hermes-opencode-notebook.tar.gz" >>"$LOG_FILE" 2>&1 || warn "download do kit falhou"
        ;;
      *)
        cp -f "$KIT_SRC" "$KIT_DIR/hermes-opencode-notebook.tar.gz"
        ;;
    esac

    working "Extraindo"
    rm -rf "$KIT_DIR/hermes-opencode-notebook"
    tar -xzf "$KIT_DIR/hermes-opencode-notebook.tar.gz" -C "$KIT_DIR"

    if [[ -x "$KIT_DIR/hermes-opencode-notebook/install.sh" ]]; then
      working "Aplicando configuração"
      ( cd "$KIT_DIR/hermes-opencode-notebook" && ./install.sh --skip-deps ) >>"$LOG_FILE" 2>&1 \
        && ok "configuração aplicada" \
        || warn "install.sh do kit falhou; veja $LOG_FILE"
    else
      warn "install.sh ausente no kit"
    fi
  fi
fi

# =============================================================================
#  ETAPA 7 — Tailscale e (opcional) SSH para o servidor
# =============================================================================
step "Tailscale e acesso ao servidor"

if have tailscale; then
  skip "tailscale $(tailscale version 2>/dev/null | head -1)"
else
  working "Instalando Tailscale"
  if retry bash -c 'curl -fsSL https://tailscale.com/install.sh | sh' >>"$LOG_FILE" 2>&1; then
    ok "Tailscale instalado"
  else
    warn "instalação do Tailscale falhou"
    show_log_tail
  fi
fi

if have tailscale; then
  if tailscale status >/dev/null 2>&1; then
    skip "já logado na tailnet"
  else
    info "Faça o login na tailnet (abre uma URL no navegador)"
    $SUDO tailscale up || warn "tailscale up não concluído; rode depois: sudo tailscale up"
  fi

  TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [[ -n "$TS_IP" ]] && ok "este notebook na tailnet: $TS_IP"
fi

if [[ "$WITH_SSH" -eq 1 ]]; then
  if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    skip "chave SSH existente"
  else
    working "Gerando chave SSH"
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "$(id -un)@$(hostname)" >/dev/null
    ok "chave criada"
  fi

  info "Copiando a chave para $SERVER_USER@$SERVER_TS_IP (vai pedir a senha uma vez)"
  if ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" "$SERVER_USER@$SERVER_TS_IP"; then
    ok "chave instalada no usuário $SERVER_USER"
    ssh -o BatchMode=yes "$SERVER_USER@$SERVER_TS_IP" \
      'sudo install -D -m 600 ~/.ssh/authorized_keys /root/.ssh/authorized_keys' \
      && ok "root do servidor liberado por chave" \
      || warn "não consegui copiar a chave para o root do servidor"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$SERVER_TS_IP" 'hostname; id -u' \
      && ok "acesso root validado" || warn "teste de root falhou"
  else
    warn "ssh-copy-id falhou; confira se o Tailscale está ativo nos dois lados"
  fi
else
  info "SSH não configurado (use --with-ssh para liberar root no servidor)"
fi

# =============================================================================
#  ETAPA 8 — validação
# =============================================================================
step "Validação final"

export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
FAIL=0

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else warn "$label"; FAIL=$((FAIL+1)); fi
}

check "git"       git --version
check "curl"      curl --version
check "python"    "$PYTHON_BIN" --version
check "hermes"    hermes --version
check "opencode"  opencode --version
[[ "$DO_DOCKER" -eq 1 ]] && check "docker" docker --version
[[ "$DO_DOCKER" -eq 1 ]] && check "compose" docker compose version
have tailscale && check "tailscale" tailscale version

echo ""
banner "RESUMO"
echo "  Python...: $("$PYTHON_BIN" --version 2>&1)"
have node     && echo "  Node.....: $(node -v)"
have docker   && echo "  Docker...: $(docker --version 2>/dev/null | cut -d, -f1)"
have hermes   && echo "  Hermes...: $(hermes --version 2>/dev/null | head -1)"
have opencode && echo "  OpenCode.: $(opencode --version 2>/dev/null | head -1)"
have tailscale && [[ -n "${TS_IP:-}" ]] && echo "  Tailnet..: $TS_IP"

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "  ${GREEN}Tudo instalado.${RESET} Próximos passos:"
else
  echo "  ${YELLOW}${FAIL} item(ns) com problema.${RESET} Veja o log: $LOG_FILE"
  echo "  Próximos passos (os que funcionaram):"
fi
echo "    hermes doctor"
echo "    hermes --profile elliot"
echo "    opencode"
if [[ "$WITH_SSH" -eq 0 ]]; then
  echo "    bash $SCRIPT_NAME --with-ssh   # libera root no servidor"
fi
echo ""
_logfile "FIM fail=$FAIL"
