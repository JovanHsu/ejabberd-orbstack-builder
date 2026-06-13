%%%-------------------------------------------------------------------
%%% @doc
%%% 消息过滤模块 - 调用外部审核 API
%%%
%%% 功能：
%%% 1. 拦截所有聊天消息
%%% 2. 调用外部审核接口
%%% 3. 根据审核结果决定是否发送消息
%%% 4. 违规消息通过 XMPP 错误回执通知发送者
%%%
%%% 日志策略：
%%%   - 正常路径使用 ?DEBUG（避免在生产打印用户消息体造成噪声/合规风险）
%%%   - 异常分支使用 ?WARNING_MSG / ?ERROR_MSG
%%%
%%% HTTP 调用：
%%%   - 使用专用 httpc profile（?HTTPC_PROFILE）隔离连接池，
%%%     避免与 ejabberd 共享 default profile 互相阻塞
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_message_filter).
-author('ejabberd@pyramidtip.com').

-behaviour(gen_mod).

%% gen_mod callbacks
-export([start/2, stop/1, reload/3, depends/2, mod_options/1, mod_opt_type/1]).

%% Hook handlers
-export([filter_packet/1]).

-include("logger.hrl").
-include("xmpp.hrl").

-define(HTTPC_PROFILE, mod_message_filter_httpc).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, _Opts) ->
    ?INFO_MSG("启动消息过滤模块, Host: ~s", [Host]),
    ok = ensure_httpc_profile(),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, filter_packet, 50),
    ok.

stop(Host) ->
    ?INFO_MSG("停止消息过滤模块, Host: ~s", [Host]),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, filter_packet, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [
        {api_url, <<"https://bc.pyramidtip.com/verify">>},
        {api_timeout, 3000},        %% 单次请求超时 (ms)
        {api_connect_timeout, 2000},%% TCP 连接超时 (ms)
        {api_key, <<"">>},
        {filter_groupchat, false},
        {filter_types, [chat, normal]},
        {fail_open, true}           %% API 异常时是否放行（默认放行，避免影响正常通信）
    ].

mod_opt_type(api_url) ->            econf:binary();
mod_opt_type(api_timeout) ->        econf:pos_int();
mod_opt_type(api_connect_timeout) ->econf:pos_int();
mod_opt_type(api_key) ->            econf:binary();
mod_opt_type(filter_groupchat) ->   econf:bool();
mod_opt_type(filter_types) ->       econf:list(econf:atom());
mod_opt_type(fail_open) ->          econf:bool().

%%====================================================================
%% Hook handlers
%%====================================================================

%% @doc 过滤消息包 - user_send_packet hook
%% ejabberd 25.x 传递 {Packet, C2SState} 元组
filter_packet({#message{type = Type, body = Body, from = From, to = To} = Packet,
               C2SState} = Input) ->
    Host = From#jid.lserver,
    FilterTypes = gen_mod:get_module_opt(Host, ?MODULE, filter_types),
    FilterGroupchat = gen_mod:get_module_opt(Host, ?MODULE, filter_groupchat),

    ShouldFilter = lists:member(Type, FilterTypes) orelse
                   (Type == groupchat andalso FilterGroupchat),
    BodyText = extract_body_text(Body),

    ?DEBUG("filter_packet type=~p from=~s to=~s should_filter=~p",
           [Type, jid:encode(From), jid:encode(To), ShouldFilter]),

    case ShouldFilter andalso BodyText =/= <<>> of
        true  -> do_filter(Host, Packet, C2SState, From, To);
        false -> Input
    end;
filter_packet(Arg) ->
    %% 非消息包（IQ/Presence 等），直接透传
    Arg.

do_filter(Host, Packet, C2SState, From, To) ->
    case verify_message(Host, Packet) of
        {ok, pass} ->
            ?DEBUG("消息审核通过", []),
            {Packet, C2SState};

        {ok, {pass_with_rewrite, NewMessage}} ->
            ?DEBUG("消息审核通过(已重写), 新长度=~p", [byte_size(NewMessage)]),
            {rewrite_body(Packet, NewMessage), C2SState};

        {ok, {reject, ReasonCode, ReasonMessage}} ->
            ?WARNING_MSG("消息被拦截 from=~s to=~s code=~s",
                         [jid:encode(From), jid:encode(To), ReasonCode]),
            {rejection_error_stanza(Packet, From, To, ReasonCode, ReasonMessage), C2SState};

        {error, Error} ->
            handle_api_error(Host, Error, Packet, C2SState, From, To)
    end.

%% @doc API 异常时按 fail_open 配置决定放行或拦截
handle_api_error(Host, Error, Packet, C2SState, From, To) ->
    case gen_mod:get_module_opt(Host, ?MODULE, fail_open) of
        true ->
            ?WARNING_MSG("审核 API 异常(放行) from=~s to=~s reason=~p",
                         [jid:encode(From), jid:encode(To), Error]),
            {Packet, C2SState};
        false ->
            ?WARNING_MSG("审核 API 异常(拦截) from=~s to=~s reason=~p",
                         [jid:encode(From), jid:encode(To), Error]),
            {rejection_error_stanza(Packet, From, To,
                                    <<"SERVICE_BUSY">>,
                                    <<"审核服务暂不可用，请稍后重试">>),
             C2SState}
    end.

%%====================================================================
%% Body 处理
%%====================================================================

%% @doc 提取主体文本（取首个 #text 元素）
extract_body_text([]) -> <<>>;
extract_body_text([#text{data = Data} | _]) -> Data;
extract_body_text([_ | Rest]) -> extract_body_text(Rest);
extract_body_text(#text{data = Data}) -> Data;
extract_body_text(_) -> <<>>.

extract_subject_text([]) -> <<>>;
extract_subject_text([#text{data = Data} | _]) -> Data;
extract_subject_text([_ | Rest]) -> extract_subject_text(Rest);
extract_subject_text(#text{data = Data}) -> Data;
extract_subject_text(_) -> <<>>.

%% @doc 用 NewText 替换消息体
%% 保留原 body 列表中的非 #text 元素和 lang 属性，仅替换 #text 元素的 data；
%% 若没有任何 #text 元素，则追加一个无 lang 的 #text。
rewrite_body(#message{body = Body} = Packet, NewText) when is_list(Body) ->
    case lists:any(fun(#text{}) -> true; (_) -> false end, Body) of
        true ->
            Packet#message{
                body = [case El of
                            #text{} = T -> T#text{data = NewText};
                            Other -> Other
                        end || El <- Body]
            };
        false ->
            Packet#message{body = [#text{data = NewText} | Body]}
    end;
rewrite_body(Packet, NewText) ->
    Packet#message{body = [#text{data = NewText}]}.

%%====================================================================
%% 序列化为 JSON
%%====================================================================

message_to_json(#message{
    id = Id, type = Type, from = From, to = To,
    subject = Subject, body = Body, thread = Thread, meta = Meta
}) ->
    Base = #{
        <<"type">> => atom_to_binary(Type, utf8),
        <<"from">> => jid:encode(From),
        <<"to">> => jid:encode(To),
        <<"timestamp">> => erlang:system_time(second)
    },
    Fs = put_optional(<<"id">>, Id, Base),
    Fs2 = put_optional(<<"body">>, extract_body_text(Body), Fs),
    Fs3 = put_optional(<<"subject">>, extract_subject_text(Subject), Fs2),
    Fs4 = put_optional(<<"thread">>, Thread, Fs3),
    Fs5 = case Body of
              [] -> Fs4;
              _  -> Fs4#{<<"body_elements">> => body_to_json(Body)}
          end,
    case Meta of
        undefined -> Fs5;
        _         -> Fs5#{<<"meta">> => meta_to_json(Meta)}
    end.

put_optional(_K, undefined, Map) -> Map;
put_optional(_K, <<>>, Map) -> Map;
put_optional(K, V, Map) -> Map#{K => V}.

meta_to_json(Meta) when is_map(Meta) ->
    maps:fold(fun(K, V, Acc) ->
        case is_serializable(V) of
            true  -> Acc#{K => V};
            false -> Acc
        end
    end, #{}, Meta);
meta_to_json(_) -> #{}.

body_to_json(Body) when is_list(Body) ->
    lists:filtermap(fun element_to_json/1, Body);
body_to_json(_) -> [].

element_to_json(#text{data = Data}) ->
    {true, #{<<"type">> => <<"text">>, <<"data">> => Data}};
element_to_json(_) ->
    false.

is_serializable(V) when is_binary(V); is_number(V); is_boolean(V); is_atom(V) -> true;
is_serializable(_) -> false.

%%====================================================================
%% HTTP / API
%%====================================================================

%% @doc 启动专用 httpc profile（idempotent）。
%% 隔离连接池，并打开 keep-alive，提升审核 API 高并发场景下的吞吐。
ensure_httpc_profile() ->
    case inets:start(httpc, [{profile, ?HTTPC_PROFILE}]) of
        {ok, _Pid} -> set_profile_options();
        {error, {already_started, _}} -> ok;
        Other ->
            ?ERROR_MSG("启动 httpc profile 失败: ~p", [Other]),
            ok
    end.

set_profile_options() ->
    httpc:set_options(
        [{max_sessions, 32},
         {max_keep_alive_length, 100},
         {keep_alive_timeout, 60000},
         {pipeline_timeout, 0}],
        ?HTTPC_PROFILE),
    ok.

verify_message(Host, Packet) ->
    ApiUrl   = gen_mod:get_module_opt(Host, ?MODULE, api_url),
    Timeout  = gen_mod:get_module_opt(Host, ?MODULE, api_timeout),
    ConnTo   = gen_mod:get_module_opt(Host, ?MODULE, api_connect_timeout),
    ApiKey   = gen_mod:get_module_opt(Host, ?MODULE, api_key),

    RequestBody = misc:json_encode(message_to_json(Packet)),
    Headers     = build_headers(ApiKey),

    ?DEBUG("调用审核 API url=~s body_size=~p", [ApiUrl, byte_size(RequestBody)]),

    try
        Result = httpc:request(
                   post,
                   {binary_to_list(ApiUrl), Headers,
                    "application/json", RequestBody},
                   [{timeout, Timeout}, {connect_timeout, ConnTo}],
                   [{body_format, binary}],
                   ?HTTPC_PROFILE),
        handle_http_result(Result)
    catch
        Class:Reason:Stack ->
            ?ERROR_MSG("调用审核 API 异常 ~p:~p~n~p", [Class, Reason, Stack]),
            {error, {exception, Class, Reason}}
    end.

build_headers(<<>>) ->
    [{"Content-Type", "application/json"}];
build_headers(Key) when is_binary(Key) ->
    [{"Content-Type", "application/json"},
     {"Authorization", "Bearer " ++ binary_to_list(Key)}].

handle_http_result({ok, {{_, 200, _}, _, ResponseBody}}) ->
    ?DEBUG("API 响应 size=~p", [byte_size(ResponseBody)]),
    parse_verify_response(ResponseBody);
handle_http_result({ok, {{_, StatusCode, _}, _, _}}) ->
    {error, {http_status, StatusCode}};
handle_http_result({error, {failed_connect, _}}) ->
    {error, connection_failed};
handle_http_result({error, timeout}) ->
    {error, timeout};
handle_http_result({error, Reason}) ->
    {error, Reason}.

%% @doc 解析审核 API 响应
%%
%% 期望 JSON 形如：
%%   通过：             {"pass": true}
%%   通过+重写：        {"pass": true, "message": "..."}
%%   拒绝：             {"pass": false, "code": "CONTENT_VIOLATION", "message": "..."}
%%
%% 兼容旧字段名 `reason`（同时承担错误码角色）：
%%   {"pass": false, "reason": "CONTENT_VIOLATION"}
%% 此时 code = reason，message 也回退到 reason。
parse_verify_response(ResponseBody) ->
    try
        Response = misc:json_decode(ResponseBody),
        case maps:get(<<"pass">>, Response, undefined) of
            true ->
                case maps:get(<<"message">>, Response, <<>>) of
                    <<>> -> {ok, pass};
                    NewMsg when is_binary(NewMsg) ->
                        {ok, {pass_with_rewrite, NewMsg}};
                    _ -> {ok, pass}
                end;
            false ->
                Code = pick_code(Response),
                Msg  = pick_message(Response, Code),
                {ok, {reject, Code, Msg}};
            _ ->
                %% 缺失或非布尔，视为 API 异常 → 走 fail_open 分支
                {error, invalid_response}
        end
    catch
        Class:Reason:_Stack ->
            ?ERROR_MSG("解析审核响应失败 ~p:~p body=~s",
                       [Class, Reason, ResponseBody]),
            {error, parse_error}
    end.

pick_code(Response) ->
    case maps:get(<<"code">>, Response, undefined) of
        Code when is_binary(Code), Code =/= <<>> -> Code;
        _ -> maps:get(<<"reason">>, Response, <<"CONTENT_VIOLATION">>)
    end.

pick_message(Response, Code) ->
    case maps:get(<<"message">>, Response, undefined) of
        Msg when is_binary(Msg), Msg =/= <<>> -> Msg;
        _ -> default_message(Code)
    end.

default_message(<<"CONTENT_VIOLATION">>)     -> <<"内容违规">>;
default_message(<<"SENSITIVE_WORD">>)        -> <<"包含敏感词">>;
default_message(<<"SPAM">>)                  -> <<"涉嫌垃圾信息">>;
default_message(<<"INAPPROPRIATE_CONTENT">>) -> <<"内容不当">>;
default_message(<<"ILLEGAL_CONTENT">>)       -> <<"涉嫌违法内容">>;
default_message(<<"INVALID_FORMAT">>)        -> <<"消息格式错误">>;
default_message(<<"CONTENT_TOO_LONG">>)      -> <<"内容过长">>;
default_message(<<"UNSUPPORTED_TYPE">>)      -> <<"不支持的消息类型">>;
default_message(<<"PERMISSION_DENIED">>)     -> <<"权限不足">>;
default_message(<<"USER_MUTED">>)            -> <<"账号已被禁言">>;
default_message(<<"USER_BLOCKED">>)          -> <<"账号已被封禁">>;
default_message(<<"RATE_LIMIT_EXCEEDED">>)   -> <<"操作过于频繁，请稍后再试">>;
default_message(<<"SERVICE_BUSY">>)          -> <<"审核服务繁忙">>;
default_message(_)                           -> <<"内容违规">>.

%%====================================================================
%% XMPP 错误回执
%%====================================================================

%% @doc 构造标准的 XMPP 错误回执。user_send_packet 是 fold hook，不能返回
%% {stop, drop}；返回 error stanza 才能让 c2s 正常发送错误且不崩溃。
rejection_error_stanza(Packet, From, To, ReasonCode, ReasonMessage) ->
    {ErrorType, ErrorCondition} = classify_rejection_reason(ReasonCode),
    ErrorText = iolist_to_binary([<<"消息未通过内容审核：">>, ReasonMessage]),
    Packet#message{
        from = To,
        to   = From,
        type = error,
        sub_els = [
            #stanza_error{
                type = ErrorType,
                reason = ErrorCondition,
                text = [#text{lang = <<"zh">>, data = ErrorText}]
            }
        ]
    }.

%% @doc 根据拒绝原因代码分类错误类型和条件
%% 返回 {ErrorType, ErrorCondition}
classify_rejection_reason(Code) when is_binary(Code) ->
    case Code of
        <<"CONTENT_VIOLATION">>     -> {cancel, 'policy-violation'};
        <<"SENSITIVE_WORD">>        -> {cancel, 'policy-violation'};
        <<"SPAM">>                  -> {cancel, 'policy-violation'};
        <<"INAPPROPRIATE_CONTENT">> -> {cancel, 'policy-violation'};
        <<"ILLEGAL_CONTENT">>       -> {cancel, 'policy-violation'};

        <<"INVALID_FORMAT">>        -> {modify, 'not-acceptable'};
        <<"CONTENT_TOO_LONG">>      -> {modify, 'not-acceptable'};
        <<"UNSUPPORTED_TYPE">>      -> {modify, 'not-acceptable'};

        <<"PERMISSION_DENIED">>     -> {auth, forbidden};
        <<"USER_MUTED">>            -> {auth, forbidden};
        <<"USER_BLOCKED">>          -> {auth, forbidden};

        <<"RATE_LIMIT_EXCEEDED">>   -> {wait, 'resource-constraint'};
        <<"SERVICE_BUSY">>          -> {wait, 'service-unavailable'};

        _ ->
            ?DEBUG("未识别的拒绝原因代码: ~s", [Code]),
            {cancel, 'policy-violation'}
    end;
classify_rejection_reason(_) ->
    {cancel, 'policy-violation'}.
