#!/usr/bin/env bash
# =============================================================================
#  PokeIdle Multi - VM Debian 13 (Trixie) + XFCE para Proxmox VE
#
#  Uso (no shell do host Proxmox, como root):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/NielDayzEclipse/pokeidle-proxmox/main/pokeidle-vm.sh)"
#
#  O que faz:
#    - Baixa a imagem oficial Debian 13 (cloud generic)
#    - Cria a VM (CPU host, VirtIO, QXL/SPICE, guest agent, inicia com o host)
#    - Via cloud-init instala: XFCE, xrdp, qemu-guest-agent, spice-vdagent,
#      Firefox ESR, dependencias do Electron, locale pt_BR, teclado ABNT2
#    - Desativa suspensao / bloqueio / descanso de tela
#    - Baixa a ultima release do PokeIdle Multi (.deb ou .AppImage) do GitHub
# =============================================================================
set -Eeuo pipefail

APP="PokeIdle Multi"
REPO_DEFAULT="NielDayzEclipse/pokeidle-multiacc"
IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"

YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'; BD=$'\033[1m'; CL=$'\033[m'
msg_info()  { echo -e " ${YW}➜${CL} $1"; }
msg_ok()    { echo -e " ${GN}✔${CL} $1"; }
msg_error() { echo -e " ${RD}✖${CL} $1" >&2; }
abort()     { clear; msg_error "Instalação cancelada."; exit 1; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'msg_error "Falhou na linha $LINENO: $BASH_COMMAND"' ERR

header() {
  clear
  cat <<EOF
${BL}
  ____       _        ___    _ _        __  __       _ _   _
 |  _ \ ___ | | _____|_ _|__| | | ___  |  \/  |_   _| | |_(_)
 | |_) / _ \| |/ / _ \| |/ _\` | |/ _ \ | |\/| | | | | | __| |
 |  __/ (_) |   <  __/| | (_| | |  __/ | |  | | |_| | | |_| |
 |_|   \___/|_|\_\___|___\__,_|_|\___| |_|  |_|\__,_|_|\__|_|
${CL}
        ${BD}VM Debian 13 + XFCE para Proxmox VE${CL}

EOF
}

# ---------------------------------------------------------------- checagens --
header
[[ $EUID -eq 0 ]] || { msg_error "Rode como root no host Proxmox."; exit 1; }
command -v qm >/dev/null && command -v pvesm >/dev/null \
  || { msg_error "Este script deve rodar no host Proxmox VE (comando 'qm' não encontrado)."; exit 1; }
[[ $(dpkg --print-architecture) == amd64 ]] || { msg_error "Somente hosts amd64."; exit 1; }
PVE_MAJOR=$(pveversion | grep -oP 'pve-manager/\K[0-9]+' || echo 0)
(( PVE_MAJOR >= 7 )) || { msg_error "Requer Proxmox VE 7.2 ou superior."; exit 1; }
command -v whiptail >/dev/null || apt-get install -y whiptail >/dev/null

# ---------------------------------------------------------------- perguntas --
BT="$APP - instalador de VM"
ask()     { local __v; __v=$(whiptail --backtitle "$BT" --title "$2" --inputbox "$3" 11 64 "$4" 3>&1 1>&2 2>&3) || abort; printf -v "$1" '%s' "$__v"; }
askpass() { local __v; __v=$(whiptail --backtitle "$BT" --title "$2" --passwordbox "$3" 10 64 3>&1 1>&2 2>&3) || abort; printf -v "$1" '%s' "$__v"; }
menu()    { local __v __var=$1 __t=$2 __p=$3; shift 3
            __v=$(whiptail --backtitle "$BT" --title "$__t" --menu "$__p" 18 70 8 "$@" 3>&1 1>&2 2>&3) || abort
            printf -v "$__var" '%s' "$__v"; }

whiptail --backtitle "$BT" --title "$APP" --yesno \
"Este script vai criar uma VM Debian 13 + XFCE pronta para rodar o $APP.\n\nContinuar?" 11 64 || abort

# VMID
NEXTID=$(pvesh get /cluster/nextid)
while :; do
  ask VMID "ID da VM" "ID da nova VM:" "$NEXTID"
  [[ $VMID =~ ^[0-9]+$ ]] && (( VMID >= 100 )) || { whiptail --msgbox "ID inválido." 8 40; continue; }
  if compgen -G "/etc/pve/nodes/*/qemu-server/$VMID.conf" >/dev/null || compgen -G "/etc/pve/nodes/*/lxc/$VMID.conf" >/dev/null; then
    whiptail --msgbox "O ID $VMID já está em uso." 8 40; continue
  fi
  break
done

# Nome
while :; do
  ask HN "Nome" "Nome (hostname) da VM:" "pokeidle"
  HN=${HN,,}
  [[ $HN =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && break
  whiptail --msgbox "Use só letras minúsculas, números e hífen." 8 50
done

# Recursos sugeridos pelo numero de contas
HOST_CORES=$(nproc)
while :; do
  ask ACCOUNTS "Contas" "Quantas contas/janelas do PokeIdle você pretende rodar?\n(usado só para sugerir CPU e RAM)" "4"
  [[ $ACCOUNTS =~ ^[0-9]+$ ]] && (( ACCOUNTS >= 1 )) && break
done
SUG_RAM=$(( (2048 + ACCOUNTS * 400 + 511) / 512 * 512 ))
SUG_CORES=$(( ACCOUNTS / 2 + 2 )); (( SUG_CORES > HOST_CORES )) && SUG_CORES=$HOST_CORES

while :; do ask CORES "CPU" "Núcleos de CPU (host tem $HOST_CORES):" "$SUG_CORES"; [[ $CORES =~ ^[0-9]+$ ]] && (( CORES >= 1 )) && break; done
while :; do ask RAM   "Memória" "RAM em MB:" "$SUG_RAM";   [[ $RAM =~ ^[0-9]+$ ]] && (( RAM >= 1024 )) && break; done
while :; do ask DISK  "Disco" "Tamanho do disco em GB:" "32"; [[ $DISK =~ ^[0-9]+$ ]] && (( DISK >= 10 )) && break; done

# Storage do disco
ST_MENU=()
while read -r name type status _ _ avail _; do
  [[ $status == active ]] || continue
  ST_MENU+=("$name" "$type - livre: $(( avail / 1024 / 1024 )) GB")
done < <(pvesm status -content images | awk 'NR>1')
(( ${#ST_MENU[@]} )) || { msg_error "Nenhum storage com suporte a discos de VM."; exit 1; }
if (( ${#ST_MENU[@]} == 2 )); then STORAGE=${ST_MENU[0]}
else menu STORAGE "Storage" "Onde salvar o disco da VM:" "${ST_MENU[@]}"; fi

# Bridge
BR_MENU=()
while read -r br; do BR_MENU+=("$br" "bridge"); done < <(ip -o link show type bridge | awk -F': ' '{print $2}' | cut -d@ -f1)
(( ${#BR_MENU[@]} )) || { msg_error "Nenhuma bridge de rede encontrada."; exit 1; }
if (( ${#BR_MENU[@]} == 2 )); then BRIDGE=${BR_MENU[0]}
else menu BRIDGE "Rede" "Bridge de rede:" "${BR_MENU[@]}"; fi

# Usuario
while :; do
  ask CI_USER "Usuário" "Usuário para logar na VM (RDP/SSH):" "pokeidle"
  [[ $CI_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $CI_USER != root ]] && break
  whiptail --msgbox "Nome de usuário inválido." 8 40
done
while :; do
  askpass PASS1 "Senha" "Senha do usuário $CI_USER:"
  askpass PASS2 "Senha" "Repita a senha:"
  [[ -n $PASS1 && $PASS1 == "$PASS2" ]] && break
  whiptail --msgbox "As senhas não conferem (ou estão vazias)." 8 50
done
PASS_HASH=$(openssl passwd -6 -stdin <<<"$PASS1")
unset PASS1 PASS2

# App
INSTALL_APP=0; REPO=$REPO_DEFAULT
if whiptail --backtitle "$BT" --title "$APP" --yesno "Baixar e instalar a última release do $APP do GitHub?" 9 64; then
  INSTALL_APP=1
  ask REPO "Repositório" "Repositório GitHub (dono/repo) com as releases:" "$REPO_DEFAULT"
fi

whiptail --backtitle "$BT" --title "Confirmar" --yesno \
"VM $VMID  ($HN)
CPU: $CORES núcleos   RAM: $RAM MB   Disco: ${DISK} GB
Storage: $STORAGE    Rede: $BRIDGE (DHCP)
Usuário: $CI_USER
Instalar $APP: $([[ $INSTALL_APP == 1 ]] && echo "sim ($REPO)" || echo não)

Criar a VM agora?" 15 66 || abort
header

# ------------------------------------------------------ storage de snippets --
SNIP_STORAGE=$(pvesm status -content snippets 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}' || true)
if [[ -z $SNIP_STORAGE ]]; then
  msg_info "Habilitando 'snippets' no storage 'local' (necessário para o cloud-init)"
  CUR=$(pvesh get /storage/local --output-format json | python3 -c 'import sys,json;print(json.load(sys.stdin).get("content",""))')
  pvesm set local --content "${CUR:+$CUR,}snippets"
  SNIP_STORAGE=local
fi
SNIP_DIR=$(pvesh get "/storage/$SNIP_STORAGE" --output-format json | python3 -c 'import sys,json;print(json.load(sys.stdin).get("path",""))')
[[ -n $SNIP_DIR ]] || { msg_error "Não achei o caminho do storage $SNIP_STORAGE."; exit 1; }
mkdir -p "$SNIP_DIR/snippets"
SNIP_FILE="pokeidle-$VMID-user.yaml"
msg_ok "Snippets em $SNIP_STORAGE"

# ---------------------------------------------- script que roda dentro da VM --
read -r -d '' GUEST_SETUP <<'GUEST' || true
#!/bin/bash
# Configuracao final da VM PokeIdle Multi (executado pelo cloud-init)
set -uo pipefail
exec > >(tee -a /var/log/pokeidle-setup.log) 2>&1
U="$1"; REPO="$2"; INSTALL_APP="$3"
export DEBIAN_FRONTEND=noninteractive
H=$(getent passwd "$U" | cut -d: -f6)
echo "== PokeIdle setup $(date) =="

# Idioma pt_BR
sed -i 's/^# *\(pt_BR.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=pt_BR.UTF-8

# Servicos
systemctl enable --now qemu-guest-agent || true
adduser xrdp ssl-cert || true
systemctl enable --now xrdp || true
echo "xfce4-session" > "$H/.xsession"
chown "$U:$U" "$H/.xsession"
systemctl set-default graphical.target

# Nada de suspender / bloquear / apagar a tela
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
apt-get purge -y light-locker xfce4-screensaver >/dev/null 2>&1 || true
cat > /etc/xdg/autostart/pokeidle-noblank.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Sem descanso de tela
Exec=sh -c "xset s off; xset s noblank; xset -dpms"
NoDisplay=true
EOF
mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="inactivity-on-ac" type="uint" value="0"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
  </property>
</channel>
EOF
# Evita pop-ups de senha do colord nas sessoes RDP
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-allow-colord.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") == 0) { return polkit.Result.YES; }
});
EOF

# PokeIdle Multi
if [[ $INSTALL_APP == 1 ]]; then
  echo "Buscando última release de $REPO..."
  PICK=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | python3 -c '
import sys, json
try:
    assets = json.load(sys.stdin).get("assets", [])
except Exception:
    assets = []
bad = ("arm64", "aarch64", "armv7", "armhf")
for ext in (".deb", ".appimage"):
    for a in assets:
        n = a.get("name", "").lower()
        if n.endswith(ext) and not any(b in n for b in bad):
            print(ext, a["browser_download_url"])
            sys.exit()
' || true)
  if [[ -z $PICK ]]; then
    echo "AVISO: nenhum .deb/.AppImage encontrado na última release de $REPO (repo privado ou sem build Linux)."
  else
    EXT=${PICK%% *}; URL=${PICK#* }
    echo "Baixando $URL"
    if [[ $EXT == .deb ]]; then
      curl -fL -o /tmp/pokeidle.deb "$URL" && apt-get install -y /tmp/pokeidle.deb
      rm -f /tmp/pokeidle.deb
    else
      mkdir -p /opt/pokeidle-multi
      curl -fL -o /opt/pokeidle-multi/PokeIdleMulti.AppImage "$URL"
      chmod +x /opt/pokeidle-multi/PokeIdleMulti.AppImage
      cat > /usr/share/applications/pokeidle-multi.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=PokeIdle Multi
Comment=Várias contas do PokeIdle
Exec=/opt/pokeidle-multi/PokeIdleMulti.AppImage %U
Icon=applications-games
Categories=Game;
Terminal=false
EOF
    fi
  fi
fi

apt-get clean
touch /var/lib/pokeidle-setup-done
echo "== PokeIdle setup concluído $(date) =="
GUEST

# ------------------------------------------------------- cloud-init user-data --
{
cat <<EOF
#cloud-config
hostname: $HN
timezone: America/Sao_Paulo
keyboard:
  layout: br
  model: abnt2
users:
  - name: $CI_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    passwd: '$PASS_HASH'
ssh_pwauth: true
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - spice-vdagent
  - xorg
  - xfce4
  - xfce4-terminal
  - xfce4-taskmanager
  - mousepad
  - lightdm
  - dbus-x11
  - xrdp
  - xorgxrdp
  - firefox-esr
  - fonts-noto-core
  - fonts-noto-color-emoji
  - locales
  - curl
  - ca-certificates
  - python3
  - xdg-utils
  - libfuse2t64
  - libnss3
  - libgbm1
  - libasound2t64
  - libsecret-1-0
  - libxss1
write_files:
  - path: /usr/local/sbin/pokeidle-setup.sh
    permissions: '0755'
    content: |
EOF
sed 's/^/      /' <<<"$GUEST_SETUP"
cat <<EOF
runcmd:
  - [bash, /usr/local/sbin/pokeidle-setup.sh, "$CI_USER", "$REPO", "$INSTALL_APP"]
EOF
} > "$SNIP_DIR/snippets/$SNIP_FILE"
chmod 600 "$SNIP_DIR/snippets/$SNIP_FILE"
msg_ok "cloud-init gerado"

# ---------------------------------------------------------------- cria a VM --
msg_info "Baixando Debian 13 (≈ 400 MB)"
curl -fL --progress-bar -o "$TMP_DIR/debian13.qcow2" "$IMG_URL"
msg_ok "Imagem baixada"

msg_info "Criando VM $VMID"
qm create "$VMID" --name "$HN" --ostype l26 --cpu host --cores "$CORES" --memory "$RAM" \
  --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single --agent enabled=1 \
  --vga qxl --tablet 1 --onboot 1 \
  --description "$APP - Debian 13 + XFCE. Acesso: RDP (porta 3389) ou SSH. Usuário: $CI_USER" >/dev/null
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$TMP_DIR/debian13.qcow2,discard=on,ssd=1,iothread=1" >/dev/null
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 --ipconfig0 ip=dhcp \
  --cicustom "user=$SNIP_STORAGE:snippets/$SNIP_FILE" >/dev/null
qm resize "$VMID" scsi0 "${DISK}G" >/dev/null
msg_ok "VM $VMID criada"

qm start "$VMID"
msg_ok "VM iniciada"

# ---------------------------------------------------- aguarda a instalacao --
echo
msg_info "Instalando XFCE e o $APP dentro da VM (leva ~10-20 min)."
echo -e "   ${BL}Pode apertar Ctrl+C: a instalação continua sozinha na VM.${CL}"
DONE=0
for _ in $(seq 1 240); do   # até 40 min
  if qm guest exec "$VMID" --timeout 10 -- test -f /var/lib/pokeidle-setup-done 2>/dev/null \
     | python3 -c 'import sys,json; sys.exit(json.load(sys.stdin).get("exitcode",1))' 2>/dev/null; then
    DONE=1; break
  fi
  printf '.'; sleep 10
done
echo

get_ip() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import sys, json
for i in json.load(sys.stdin):
    if i.get("name") == "lo": continue
    for a in i.get("ip-addresses", []):
        if a.get("ip-address-type") == "ipv4":
            print(a["ip-address"]); sys.exit()
' 2>/dev/null || true
}

if (( DONE )); then
  msg_ok "Instalação concluída"
  msg_info "Reiniciando a VM para subir a interface gráfica"
  qm reboot "$VMID" >/dev/null 2>&1 || true
  sleep 40
  IP=$(get_ip)
  echo
  echo -e "${GN}${BD}  Pronto! ${CL}"
  echo -e "  Área de Trabalho Remota (mstsc): ${BD}${IP:-<IP da VM>}${CL}"
  echo -e "  SSH:                             ${BD}ssh $CI_USER@${IP:-<IP da VM>}${CL}"
  echo -e "  Usuário: ${BD}$CI_USER${CL}  (senha que você definiu)"
  echo -e "  O $APP fica no menu de aplicativos > Jogos."
  echo -e "  Log da instalação na VM: /var/log/pokeidle-setup.log"
else
  IP=$(get_ip)
  msg_error "A instalação ainda não terminou (ou falhou)."
  echo -e "  Veja o console da VM $VMID no Proxmox, ou entre via SSH (${IP:-IP da VM}) e confira:"
  echo -e "    sudo tail -f /var/log/cloud-init-output.log /var/log/pokeidle-setup.log"
  echo -e "  Quando terminar, reinicie a VM: ${BD}qm reboot $VMID${CL}"
fi
