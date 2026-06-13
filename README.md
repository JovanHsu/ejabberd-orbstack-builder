# ejabberd-orbstack-builder

Builds a multi-arch ejabberd image for OrbStack / Apple Silicon.

Base image: `ghcr.io/processone/ejabberd:latest`
Output image: `ghcr.io/jovanhsu/ejabberd-orbstack:latest`

Run locally:

```bash
docker pull ghcr.io/jovanhsu/ejabberd-orbstack:latest
docker run -d --name ejabberd \
  -p 5222:5222 \
  -p 5269:5269 \
  -p 5280:5280 \
  -p 5443:5443 \
  ghcr.io/jovanhsu/ejabberd-orbstack:latest
```
