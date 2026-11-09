# setup

Script único para preparar um notebook Linux zerado com o stack de desenvolvimento:
Python, Node, Docker, Hermes Agent, OpenCode, Tailscale e o kit de configuração
do servidor.

## Uso

```bash
curl -fsSL https://raw.githubusercontent.com/LEMOSTECHIT/setup/main/setup_notebook.sh -o setup_notebook.sh && bash setup_notebook.sh
```

Com acesso root ao servidor:

```bash
curl -fsSL https://raw.githubusercontent.com/LEMOSTECHIT/setup/main/setup_notebook.sh -o setup_notebook.sh && bash setup_notebook.sh --with-ssh
```

## Opções

| Opção | Efeito |
|---|---|
| `--bundle PATH\|URL` | kit do Hermes/OpenCode (`.tar.gz`) |
| `--with-ssh` | gera chave e libera root no servidor |
| `--no-docker` | não instala Docker |
| `--skip-kit` | só as ferramentas, sem aplicar configuração |
| `--yes` | não pergunta nada |

## O que ele faz

1. Detecta o sistema e instala as ferramentas base
2. Python 3.12+ com venv
3. Node.js 22 LTS (com fallback por tarball se o apt estiver quebrado)
4. Docker + Compose (opcional)
5. Hermes Agent
6. OpenCode
7. Kit de configuração (config, skills, perfil, REA)
8. Tailscale e acesso SSH ao servidor
9. Validação com resumo

Idempotente: pode rodar quantas vezes quiser. Log em `~/setup_notebook.log`.

## Espelho

O mesmo arquivo também é servido em `https://lemostech.dev.br/setup`.
