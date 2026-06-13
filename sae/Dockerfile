FROM ghcr.io/processone/ejabberd:latest

LABEL org.opencontainers.image.title="ejabberd-sae"
LABEL org.opencontainers.image.description="ejabberd for Aliyun SAE: xmpp.pyramidtip.com, SQL-backed, bundled custom modules"
LABEL org.opencontainers.image.source="https://github.com/JovanHsu/ejabberd-orbstack-builder"

USER root
RUN apk add --no-cache gettext

COPY --chown=9000:9000 conf/ejabberd.yml.template /opt/ejabberd/conf/ejabberd.yml.template
COPY --chown=9000:9000 modules/ /opt/ejabberd/.ejabberd-modules/
COPY --chown=9000:9000 bin/sae-entrypoint.sh /opt/ejabberd/bin/sae-entrypoint.sh

RUN chmod +x /opt/ejabberd/bin/sae-entrypoint.sh \
    && chmod -R u+rwX,go+rX /opt/ejabberd/conf /opt/ejabberd/.ejabberd-modules

USER 9000
ENTRYPOINT ["/opt/ejabberd/bin/sae-entrypoint.sh"]
CMD ["foreground"]
