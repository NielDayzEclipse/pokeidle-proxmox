# PokeIdle Multi – VM para Proxmox VE

Cria automaticamente uma VM **Debian 13 + XFCE** no Proxmox, pronta para rodar o
[PokeIdle Multi](https://github.com/NielDayzEclipse/pokeidle-multiacc) com várias contas.

## Instalação

No shell do host Proxmox (como root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/NielDayzEclipse/pokeidle-proxmox/main/pokeidle-vm.sh)"
```

O script pergunta ID, nome, quantidade de contas (para sugerir CPU/RAM), disco,
storage, rede, usuário e senha. Depois disso é só esperar ~10–20 minutos.

## O que vem instalado

- Debian 13 (Trixie) com XFCE, idioma pt_BR e teclado ABNT2
- xrdp (Área de Trabalho Remota do Windows), SSH, qemu-guest-agent, spice-vdagent
- Firefox ESR e as bibliotecas que o Electron precisa
- Suspensão, bloqueio e descanso de tela desativados (para rodar 24/7)
- A última release Linux (`.deb` ou `.AppImage`) do PokeIdle Multi

## Acesso

- **Área de Trabalho Remota:** `mstsc` → IP da VM (o script mostra no final)
- **SSH:** `ssh usuario@IP`
- Log da instalação dentro da VM: `/var/log/pokeidle-setup.log`

## Requisitos

- Proxmox VE 7.2 ou superior (amd64)
- Internet no host e na VM (DHCP)
- Para instalar o app, as releases do repositório do PokeIdle Multi precisam ser públicas
  e ter um arquivo `.deb` ou `.AppImage` para Linux x64
