# ejabberd-orbstack-builder

Builds ejabberd images in GitHub Actions so local Mac/OrbStack does not need to pull slow base layers.

## Images

### OrbStack / Apple Silicon image

- Context: repository root
- Workflow: `.github/workflows/build.yml`
- Output: `ghcr.io/jovanhsu/ejabberd-orbstack:latest`
- Platforms: `linux/amd64`, `linux/arm64`

Local run:

```bash
docker pull ghcr.io/jovanhsu/ejabberd-orbstack:latest
docker run -d --name ejabberd \
  -p 5222:5222 \
  -p 5269:5269 \
  -p 5280:5280 \
  -p 5443:5443 \
  ghcr.io/jovanhsu/ejabberd-orbstack:latest
```

### Aliyun SAE image

- Context: `sae/`
- Workflow: `.github/workflows/build-sae.yml`
- Output: `registry.pyramidtip.com/library/ejabberd:latest`
- Platform: `linux/amd64`
- Domain: `xmpp.pyramidtip.com`

The SAE image bundles:

- `sae/conf/ejabberd.yml.template`
- official `.ejabberd-modules` custom modules under `sae/modules/`
- `sae/bin/sae-entrypoint.sh`, which renders runtime env vars into ejabberd config before startup

Required GitHub secrets for pushing SAE image:

- `PYRAMIDTIP_REGISTRY_USERNAME`
- `PYRAMIDTIP_REGISTRY_PASSWORD`

Trigger manually:

```bash
gh workflow run build-sae.yml -f image_tag=latest
```

Runtime env expected in SAE:

- `XMPP_DOMAIN=xmpp.pyramidtip.com`
- `POSTGRES_HOST`
- `POSTGRES_PORT`
- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `MESSAGE_FILTER_API_URL`
- `MESSAGE_FILTER_API_KEY`
- `OFFLINE_PUSH_URL`
- `OFFLINE_PUSH_API_KEY`
- `EJABBERD_LOG_LEVEL`

Do not commit secrets, database files, logs, or certificates.

## Local stack with PostgreSQL and Redis

Local compose stack:

```bash
cd /Users/xujian/workspace/ejabberd-orbstack-builder
cp local/.env.local.example local/.env.local

docker compose --env-file local/.env.local -f docker-compose.local.yml up -d
python3 scripts/verify_local_stack.py
```

The local stack uses:

- `ejabberd-local-stack`
- `ejabberd-local-postgres`
- `ejabberd-local-redis`
- domain `xmpp.narsk.dpdns.org`

See `local/VERIFY.md` for the full verification contract. The verifier proves raw XMPP communication and both custom modules:

- `mod_message_filter`: pass / rewrite / reject
- `mod_offline_push`: offline push callback
