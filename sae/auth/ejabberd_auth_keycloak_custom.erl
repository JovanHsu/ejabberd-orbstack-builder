%%%-------------------------------------------------------------------
%%% @doc Keycloak JWT authentication backend for ejabberd.
%%%
%%% SASL PLAIN password is expected to be a Keycloak access_token.
%%% The module verifies JWT signature via JWKS and checks issuer, expiry,
%%% and username claim.
%%%
%%% ejabberd auth method name:
%%%   auth_method:
%%%     - keycloak_custom
%%%     - sql
%%%-------------------------------------------------------------------
-module(ejabberd_auth_keycloak_custom).
-behaviour(ejabberd_auth).

-export([start/1, stop/1,
         check_password/4,
         try_register/4,
         get_users/2,
         count_users/2,
         user_exists/2,
         remove_user/2,
         store_type/1,
         plain_password_required/1,
         use_cache/1]).
-export([refresh_jwks/1]).

-include("logger.hrl").

-record(state, {
    jwks_url = <<>>        :: binary(),
    jwks_cache = #{}       :: map(),
    jwks_last_update = 0   :: integer(),
    jwks_cache_ttl = 3600  :: integer(),
    jid_field = <<"preferred_username">> :: binary(),
    issuer = undefined     :: binary() | undefined
}).

start(Host) ->
    ?INFO_MSG("Starting Keycloak JWT authentication for ~s", [Host]),
    JwksUrl = get_env_bin("KEYCLOAK_JWKS_URL",
                          <<"https://kc.pyramidtip.com/realms/cadoo/protocol/openid-connect/certs">>),
    JidField = get_env_bin("KEYCLOAK_JID_FIELD", <<"name">>),
    Issuer0 = get_env_bin("KEYCLOAK_ISSUER", <<"https://kc.pyramidtip.com/realms/cadoo">>),
    Issuer = case Issuer0 of <<>> -> undefined; _ -> Issuer0 end,
    CacheTTL = get_env_int("KEYCLOAK_JWKS_CACHE_TTL", 3600),

    ?INFO_MSG("Keycloak JWKS URL: ~s", [JwksUrl]),
    ?INFO_MSG("Keycloak JID field: ~s", [JidField]),
    ?INFO_MSG("Keycloak issuer: ~p", [Issuer]),
    ?INFO_MSG("Keycloak JWKS cache TTL: ~p seconds", [CacheTTL]),

    ok = ensure_httpc(),
    TableName = get_table_name(Host),
    case ets:info(TableName) of
        undefined -> ets:new(TableName, [named_table, public, set, {read_concurrency, true}]);
        _ -> ok
    end,

    State = #state{
        jwks_url = JwksUrl,
        jwks_cache_ttl = CacheTTL,
        jid_field = JidField,
        issuer = Issuer
    },

    State2 = case fetch_and_cache_jwks(State) of
        {ok, NewState} ->
            ?INFO_MSG("Keycloak auth started for ~s with ~p JWKS keys",
                      [Host, maps:size(NewState#state.jwks_cache)]),
            NewState;
        {error, Reason} ->
            ?ERROR_MSG("Failed to fetch Keycloak JWKS at startup: ~p", [Reason]),
            State
    end,
    ets:insert(TableName, {state, State2}),
    ok.

stop(Host) ->
    ?INFO_MSG("Stopping Keycloak JWT authentication for ~s", [Host]),
    TableName = get_table_name(Host),
    case ets:info(TableName) of
        undefined -> ok;
        _ -> ets:delete(TableName)
    end,
    ok.

check_password(User, _AuthzId, Server, Password) ->
    case get_state(Server) of
        {ok, State} ->
            Now = erlang:system_time(second),
            State2 = maybe_refresh_jwks(Server, State, Now),
            verify_jwt_token(User, Password, State2);
        {error, Reason} ->
            ?ERROR_MSG("Keycloak auth state unavailable for ~s: ~p", [Server, Reason]),
            false
    end.

try_register(_User, _AuthzId, _Server, _Password) ->
    %% Let SQL handle registration when sql is also enabled.
    pass.

get_users(_Server, _Opts) -> [].
count_users(_Server, _Opts) -> 0.
user_exists(_User, _Server) -> false.
remove_user(_User, _Server) -> {error, not_allowed}.
store_type(_Server) -> external.
plain_password_required(_Server) -> true.
use_cache(_Server) -> false.

refresh_jwks(Server) ->
    case get_state(Server) of
        {ok, State} ->
            case fetch_and_cache_jwks(State) of
                {ok, NewState} ->
                    ets:insert(get_table_name(Server), {state, NewState}),
                    {ok, maps:size(NewState#state.jwks_cache)};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

maybe_refresh_jwks(Server, #state{jwks_last_update = Last, jwks_cache_ttl = TTL} = State, Now)
  when (Now - Last) > TTL ->
    case fetch_and_cache_jwks(State) of
        {ok, NewState} ->
            ets:insert(get_table_name(Server), {state, NewState}),
            NewState;
        {error, Reason} ->
            ?WARNING_MSG("Failed to refresh Keycloak JWKS: ~p; using cached keys", [Reason]),
            State
    end;
maybe_refresh_jwks(_Server, State, _Now) ->
    State.

fetch_and_cache_jwks(#state{jwks_url = JwksUrl} = State) ->
    try
        Url = binary_to_list(JwksUrl),
        case httpc:request(get, {Url, []}, [{timeout, 10000}], [{body_format, binary}]) of
            {ok, {{_, 200, _}, _Headers, Body}} ->
                case misc:json_decode(Body) of
                    #{<<"keys">> := Keys} when is_list(Keys) ->
                        KeyCache = lists:foldl(fun jwk_to_cache/2, #{}, Keys),
                        Now = erlang:system_time(second),
                        {ok, State#state{jwks_cache = KeyCache, jwks_last_update = Now}};
                    Other ->
                        ?ERROR_MSG("Invalid JWKS body: ~p", [Other]),
                        {error, invalid_jwks_format}
                end;
            {ok, {{_, Status, _}, _Headers, Body}} ->
                {error, {http_error, Status, Body}};
            {error, Reason} ->
                {error, {http_error, Reason}}
        end
    catch
        Class:FetchReason:Stack ->
            ?ERROR_MSG("Exception fetching JWKS ~p:~p~n~p", [Class, FetchReason, Stack]),
            {error, {exception, Class, FetchReason}}
    end.

jwk_to_cache(Key, Acc) when is_map(Key) ->
    case maps:get(<<"kid">>, Key, undefined) of
        undefined -> Acc;
        Kid ->
            try maps:put(Kid, jose_jwk:from_map(Key), Acc)
            catch Class:Reason ->
                ?WARNING_MSG("Skipping invalid JWK kid=~p error=~p:~p", [Kid, Class, Reason]),
                Acc
            end
    end;
jwk_to_cache(_Other, Acc) -> Acc.

verify_jwt_token(User, Token, #state{jwks_cache = KeyCache, jid_field = JidField, issuer = Issuer}) ->
    TokenBin = to_bin(Token),
    case is_valid_jwt_format(TokenBin) of
        false -> false;
        true -> verify_with_keys(to_bin(User), TokenBin, maps:to_list(KeyCache), JidField, Issuer)
    end.

verify_with_keys(_User, _Token, [], _JidField, _Issuer) ->
    false;
verify_with_keys(User, Token, [{Kid, JWK} | Rest], JidField, Issuer) ->
    try jose_jwt:verify(JWK, Token) of
        {true, JWT, _JWS} ->
            Claims = element(2, JWT),
            case claims_valid(User, Claims, JidField, Issuer) of
                true ->
                    ?INFO_MSG("Keycloak JWT verified for user ~s with kid ~p", [User, Kid]),
                    true;
                false -> false
            end;
        {false, _, _} ->
            verify_with_keys(User, Token, Rest, JidField, Issuer)
    catch
        _:_ -> verify_with_keys(User, Token, Rest, JidField, Issuer)
    end.

claims_valid(User, Claims, JidField, Issuer) when is_map(Claims) ->
    Now = erlang:system_time(second),
    IssuerValid = case Issuer of
        undefined -> true;
        _ -> maps:get(<<"iss">>, Claims, undefined) =:= Issuer
    end,
    Exp = maps:get(<<"exp">>, Claims, 0),
    NotExpired = is_integer(Exp) andalso Exp > Now,
    TokenUser = maps:get(JidField, Claims, undefined),
    UserMatch = case TokenUser of
        undefined -> false;
        _ -> normalize_user(TokenUser) =:= normalize_user(User)
    end,
    case {IssuerValid, NotExpired, UserMatch} of
        {true, true, true} -> true;
        _ ->
            ?WARNING_MSG("Keycloak JWT rejected issuer_ok=~p not_expired=~p user_match=~p user=~p token_user=~p",
                         [IssuerValid, NotExpired, UserMatch, User, TokenUser]),
            false
    end;
claims_valid(_User, _Claims, _JidField, _Issuer) -> false.

normalize_user(User) when is_binary(User) ->
    case binary:split(User, <<"@">>) of
        [Local, _Domain] -> normalize_user(Local);
        _ ->
            case binary:split(User, <<" ">>, [global]) of
                [Local2, Local2] -> Local2;
                [Local2 | _] -> Local2;
                _ -> User
            end
    end;
normalize_user(User) -> normalize_user(to_bin(User)).

is_valid_jwt_format(Token) when is_binary(Token) ->
    case binary:split(Token, <<".">>, [global]) of
        [A, B, C] -> is_base64url_part(A) andalso is_base64url_part(B) andalso is_base64url_part(C);
        _ -> false
    end;
is_valid_jwt_format(_) -> false.

is_base64url_part(<<>>) -> false;
is_base64url_part(Part) when is_binary(Part) ->
    is_base64url_chars(Part).

is_base64url_chars(<<>>) -> true;
is_base64url_chars(<<C, Rest/binary>>) ->
    Valid = (C >= $A andalso C =< $Z) orelse
            (C >= $a andalso C =< $z) orelse
            (C >= $0 andalso C =< $9) orelse
            C =:= $- orelse C =:= $_ orelse C =:= $=,
    Valid andalso is_base64url_chars(Rest).

get_state(Server) ->
    TableName = get_table_name(Server),
    case ets:info(TableName) of
        undefined -> {error, not_initialized};
        _ ->
            case ets:lookup(TableName, state) of
                [{state, State}] -> {ok, State};
                [] -> {error, not_initialized}
            end
    end.

get_table_name(Host) ->
    HostStr = binary_to_list(to_bin(Host)),
    list_to_atom("ejabberd_auth_keycloak_custom_" ++ HostStr).

ensure_httpc() ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    application:ensure_all_started(jose),
    ok.

get_env_bin(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> list_to_binary(Value)
    end.

get_env_int(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value ->
            case catch list_to_integer(Value) of
                I when is_integer(I), I > 0 -> I;
                _ -> Default
            end
    end.

to_bin(Value) when is_binary(Value) -> Value;
to_bin(Value) when is_list(Value) -> list_to_binary(Value);
to_bin(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_bin(Value) -> iolist_to_binary(io_lib:format("~p", [Value])). 
