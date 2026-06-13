# SAE image build context

This directory builds the Aliyun SAE image for `xmpp.pyramidtip.com`.

It does not depend on local Docker volumes. Runtime config is rendered from environment variables by `bin/sae-entrypoint.sh`.

Required runtime env:

- `POSTGRES_HOST`
- `POSTGRES_PORT` (defaults to `5432`)
- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `XMPP_DOMAIN` (defaults to `xmpp.pyramidtip.com`)

Optional env:

- `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`
- `MESSAGE_FILTER_API_URL`, `MESSAGE_FILTER_API_KEY`
- `OFFLINE_PUSH_URL`, `OFFLINE_PUSH_API_KEY`
- `EJABBERD_LOG_LEVEL`

Build remotely via GitHub Actions workflow `build-sae.yml`.
