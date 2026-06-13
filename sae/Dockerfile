FROM ghcr.io/processone/ejabberd:latest

LABEL org.opencontainers.image.title="ejabberd-sae"
LABEL org.opencontainers.image.description="ejabberd for Aliyun SAE: xmpp.pyramidtip.com, SQL-backed, bundled custom modules"
LABEL org.opencontainers.image.source="https://github.com/JovanHsu/ejabberd-orbstack-builder"

USER root

COPY --chown=9000:9000 conf/ejabberd.yml.template /opt/ejabberd/conf/ejabberd.yml.template
COPY --chown=9000:9000 modules/ /opt/ejabberd/.ejabberd-modules/
COPY --chown=9000:9000 auth/ejabberd_auth_keycloak_custom.erl /tmp/ejabberd_auth_keycloak_custom.erl
COPY --chown=9000:9000 bin/sae-entrypoint.sh /opt/ejabberd/bin/sae-entrypoint.sh

RUN EJABBERD_EBIN="/opt/ejabberd-26.04/lib/ejabberd-26.4.0/ebin" \
    && cd /opt/ejabberd-26.04/bin \
    && ERL_LIBS="/opt/ejabberd-26.04/lib" /opt/ejabberd-26.04/erts-16.3.1/bin/erl \
        -boot ../releases/26.4.0/start_clean -boot_var RELEASE_LIB ../lib -noshell \
        -pa /opt/ejabberd-26.04/lib/*/ebin \
        -eval 'R=compile:file("/tmp/ejabberd_auth_keycloak_custom.erl", [{outdir, "'"$EJABBERD_EBIN"'"}, {i, "/opt/ejabberd-26.04/lib/ejabberd-26.4.0/include"}, report_errors, report_warnings]), io:format("~p~n", [R]), case R of {ok, _} -> init:stop(0); _ -> init:stop(1) end.' \
    && rm -f /tmp/ejabberd_auth_keycloak_custom.erl \
    && chmod +x /opt/ejabberd/bin/sae-entrypoint.sh \
    && chmod -R u+rwX,go+rX /opt/ejabberd/conf /opt/ejabberd/.ejabberd-modules \
    && chmod go+r "$EJABBERD_EBIN/ejabberd_auth_keycloak_custom.beam"

# Keep the named user from the official image. Using numeric USER 9000 makes
# Erlang fail at boot with kernel/user_drv `nouser` in this image.
USER ejabberd
ENTRYPOINT ["/opt/ejabberd/bin/sae-entrypoint.sh"]
CMD ["foreground"]
