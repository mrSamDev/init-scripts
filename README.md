# Dev Startup Scripts

A collection of one-command local setup scripts for various services and products. Each service lives in its own subfolder with an `init.sh` that handles everything from cloning to running.

## Services

| Service | Description | Script |
|---------|-------------|--------|
| [Pimcore](#pimcore) | Pimcore CMS + ecommerce demo via Docker | `./pimcore/init.sh` |

---

## Pimcore

Cross-platform Docker setup for the [Pimcore demo](https://github.com/pimcore/demo).

### Requirements

- Docker
- Docker Compose

### Usage

```bash
./pimcore/init.sh
```

Supports macOS, Linux, and Windows (WSL/Git Bash).

### What it spins up

| Container | Purpose |
|-----------|---------|
| nginx | Web server (port 80) |
| php | PHP 8.3 application |
| db | MariaDB 10.11 |
| redis | Cache (128 MB) |
| supervisord | Background job processor |
| gotenberg | Document/PDF conversion |
| mailpit | Email testing UI (port 8025) |

### Access

| URL | Credentials |
|-----|-------------|
| http://localhost/admin | admin / admin |
| http://localhost:8025 | — (Mailpit) |
