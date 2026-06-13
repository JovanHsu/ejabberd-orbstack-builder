%%%-------------------------------------------------------------------
%%% @doc
%%% 离线消息推送模块 - 通过推送网关发送离线消息通知
%%%
%%% 设计要点：
%%%   1. offline_message_hook 是 run_fold hook，必须透传 Acc，
%%%      并尊重上游 {stop, _} 中止信号，避免重复推送。
%%%   2. 异步推送通过有界 worker pool 完成，限制同时 inflight 的
%%%      推送数量，避免高峰期 OOM；超限时直接丢弃并打 WARNING。
%%%   3. 同一 (From, To) 在 dedup_window_ms 内的多条消息合并为单次
%%%      "X 条新消息" 推送，防止离线洪峰造成推送风暴。
%%%   4. 使用专用 httpc profile 隔离连接池。
%%%   5. 正常路径只打 ?DEBUG，避免日志污染与 PII 风险。
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_offline_push).
-author('ejabberd@pyramidtip.com').

-behaviour(gen_mod).
-behaviour(gen_server).

%% gen_mod callbacks
-export([start/2, stop/1, reload/3, depends/2, mod_options/1, mod_opt_type/1]).

%% gen_server callbacks（用于 dedup/限流 worker）
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Hook handlers
-export([push_offline_message/4]).

-include("logger.hrl").
-include("xmpp.hrl").

-define(HTTPC_PROFILE, mod_offline_push_httpc).
-define(INFLIGHT_TAB, mod_offline_push_inflight).
-define(DEDUP_TAB, mod_offline_push_dedup).
-define(SERVER(Host), gen_mod:get_module_proc(Host, ?MODULE)).

%% dedup 缓冲项
-record(dedup_entry, {
    key            :: {binary(), binary()},  %% {FromBare, ToBare}
    count = 1      :: non_neg_integer(),
    first_packet   :: term(),                %% 首条消息（推送时使用其内容预览）
    from           :: term(),
    to             :: term(),
    timer_ref      :: reference() | undefined
}).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("启动离线消息推送模块, Host: ~s", [Host]),
    ok = ensure_httpc_profile(),
    ok = ensure_inflight_table(),
    %% 启动 per-host gen_server 用于 dedup
    Proc = ?SERVER(Host),
    ChildSpec = {Proc,
                 {gen_server, start_link,
                  [{local, Proc}, ?MODULE, [Host, Opts], []]},
                 transient, 5000, worker, [?MODULE]},
    case supervisor:start_child(ejabberd_gen_mod_sup, ChildSpec) of
        {ok, _}                       -> ok;
        {error, {already_started, _}} -> ok;
        {error, already_present} ->
            supervisor:delete_child(ejabberd_gen_mod_sup, Proc),
            {ok, _} = supervisor:start_child(ejabberd_gen_mod_sup, ChildSpec),
            ok;
        Other ->
            ?WARNING_MSG("无法启动 dedup worker，回退到无 dedup 模式: ~p", [Other]),
            ok
    end,
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, push_offline_message, 50),
    ok.

stop(Host) ->
    ?INFO_MSG("停止离线消息推送模块, Host: ~s", [Host]),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, push_offline_message, 50),
    Proc = ?SERVER(Host),
    catch gen_server:stop(Proc),
    catch supervisor:delete_child(ejabberd_gen_mod_sup, Proc),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [
        {push_url, <<"https://push.pyramidtip.com/notify">>},
        {push_timeout, 3000},
        {push_connect_timeout, 2000},
        {push_api_key, <<"">>},
        {push_enabled, true},
        {push_types, [chat, normal]},
        {push_retry, 1},
        {push_async, true},
        {push_max_inflight, 1000},   %% 全局并发推送上限
        {dedup_window_ms, 0},        %% 0 = 关闭合并；>0 表示窗口毫秒数
        {dedup_max_count, 50}        %% 单个会话窗口内最多累计的消息数
    ].

mod_opt_type(push_url) ->             econf:binary();
mod_opt_type(push_timeout) ->         econf:pos_int();
mod_opt_type(push_connect_timeout) -> econf:pos_int();
mod_opt_type(push_api_key) ->         econf:binary();
mod_opt_type(push_enabled) ->         econf:bool();
mod_opt_type(push_types) ->           econf:list(econf:atom());
mod_opt_type(push_retry) ->           econf:non_neg_int();
mod_opt_type(push_async) ->           econf:bool();
mod_opt_type(push_max_inflight) ->    econf:pos_int();
mod_opt_type(dedup_window_ms) ->      econf:non_neg_int();
mod_opt_type(dedup_max_count) ->      econf:pos_int().

%%====================================================================
%% Hook handlers
%%====================================================================

%% @doc offline_message_hook 是 run_fold，必须透传 Acc。
%% 上游若返回 {stop, _}，跳过推送；否则原样返回 Acc，不影响后续 hook 链。
push_offline_message({stop, _} = Acc, _From, _To, _Packet) ->
    Acc;
push_offline_message(Acc, From, To, Packet) ->
    try
        try_push(From, To, Packet)
    catch
        Class:Reason:Stack ->
            ?ERROR_MSG("处理离线消息推送异常 ~p:~p~n~p",
                       [Class, Reason, Stack])
    end,
    Acc.

try_push(From, To, Packet) ->
    Host = To#jid.lserver,
    case gen_mod:get_module_opt(Host, ?MODULE, push_enabled)
         andalso should_push_message(Host, Packet) of
        true ->
            DedupWindow = gen_mod:get_module_opt(Host, ?MODULE, dedup_window_ms),
            case DedupWindow > 0 of
                true  -> enqueue_dedup(Host, From, To, Packet);
                false -> dispatch_push(Host, From, To, Packet)
            end;
        false ->
            ok
    end.

%% @doc 判断消息是否需要推送
should_push_message(Host, #message{type = Type, body = Body}) ->
    PushTypes = gen_mod:get_module_opt(Host, ?MODULE, push_types),
    lists:member(Type, PushTypes)
        andalso extract_body_text(Body) =/= <<>>;
should_push_message(_Host, _Packet) ->
    false.

%%====================================================================
%% 派发：同步 / 异步（有界）
%%====================================================================

dispatch_push(Host, From, To, Packet) ->
    case gen_mod:get_module_opt(Host, ?MODULE, push_async) of
        true  -> async_push(Host, From, To, Packet, 1);
        false -> do_push_message(Host, From, To, Packet, 1)
    end.

%% @doc 有界异步推送：通过 ets atomic counter 限制 inflight。
%% 策略：先 +1，若超过上限则立即 -1 回退并丢弃。
%% 短暂超额可能发生（在回退完成之前），但最终会自我修正，无累积偏差。
async_push(Host, From, To, Packet, Count) ->
    MaxInflight = gen_mod:get_module_opt(Host, ?MODULE, push_max_inflight),
    N = ets:update_counter(?INFLIGHT_TAB, inflight, 1),
    case N =< MaxInflight of
        true ->
            spawn_worker(Host, From, To, Packet, Count);
        false ->
            ets:update_counter(?INFLIGHT_TAB, inflight, -1),
            ?WARNING_MSG("推送超过并发上限(~p)，丢弃 from=~s to=~s",
                         [MaxInflight, jid:encode(From), jid:encode(To)]),
            ok
    end.

spawn_worker(Host, From, To, Packet, Count) ->
    spawn(fun() ->
        try
            do_push_message(Host, From, To, Packet, Count)
        catch
            Class:Reason:Stack ->
                ?ERROR_MSG("推送 worker 异常 ~p:~p~n~p", [Class, Reason, Stack])
        after
            ets:update_counter(?INFLIGHT_TAB, inflight, -1)
        end
    end),
    ok.

ensure_inflight_table() ->
    case ets:info(?INFLIGHT_TAB) of
        undefined ->
            ets:new(?INFLIGHT_TAB,
                    [named_table, public, set,
                     {write_concurrency, true},
                     {read_concurrency, true}]),
            ets:insert(?INFLIGHT_TAB, {inflight, 0}),
            ok;
        _ ->
            ok
    end.

%%====================================================================
%% gen_server: dedup 缓冲
%%
%% 同一 {From, To} 在窗口内的连续消息合并：
%%   - 首条到达：插入条目，启动 dedup_window_ms 定时器
%%   - 后续到达：count + 1（达到 dedup_max_count 立即 flush）
%%   - 定时器触发：合并推送一次
%%====================================================================

init([Host, _Opts]) ->
    case ets:info(?DEDUP_TAB) of
        undefined ->
            ets:new(?DEDUP_TAB,
                    [named_table, public, set,
                     {keypos, #dedup_entry.key},
                     {write_concurrency, true}]);
        _ -> ok
    end,
    {ok, #{host => Host}}.

handle_call(_Req, _From, State) -> {reply, ok, State}.

handle_cast({enqueue, From, To, Packet}, #{host := Host} = State) ->
    do_enqueue(Host, From, To, Packet),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({flush, Key}, #{host := Host} = State) ->
    flush_key(Host, Key),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

%% @doc 把消息扔进 dedup 队列（异步处理）
enqueue_dedup(Host, From, To, Packet) ->
    Proc = ?SERVER(Host),
    case erlang:whereis(Proc) of
        undefined ->
            %% dedup worker 未启动，回退到直推
            dispatch_push_no_dedup(Host, From, To, Packet);
        _Pid ->
            gen_server:cast(Proc, {enqueue, From, To, Packet})
    end.

dispatch_push_no_dedup(Host, From, To, Packet) ->
    case gen_mod:get_module_opt(Host, ?MODULE, push_async) of
        true  -> async_push(Host, From, To, Packet, 1);
        false -> do_push_message(Host, From, To, Packet, 1)
    end.

do_enqueue(Host, From, To, Packet) ->
    Key = dedup_key(From, To),
    Window = gen_mod:get_module_opt(Host, ?MODULE, dedup_window_ms),
    MaxCount = gen_mod:get_module_opt(Host, ?MODULE, dedup_max_count),
    case ets:lookup(?DEDUP_TAB, Key) of
        [] ->
            TRef = erlang:send_after(Window, self(), {flush, Key}),
            Entry = #dedup_entry{
                key          = Key,
                count        = 1,
                first_packet = Packet,
                from         = From,
                to           = To,
                timer_ref    = TRef
            },
            ets:insert(?DEDUP_TAB, Entry);
        [#dedup_entry{count = C, timer_ref = TRef} = Entry] ->
            NewCount = C + 1,
            case NewCount >= MaxCount of
                true ->
                    cancel_timer(TRef),
                    ets:delete(?DEDUP_TAB, Key),
                    push_aggregated(Host, Entry#dedup_entry{count = NewCount});
                false ->
                    ets:insert(?DEDUP_TAB,
                               Entry#dedup_entry{count = NewCount})
            end
    end.

flush_key(Host, Key) ->
    case ets:lookup(?DEDUP_TAB, Key) of
        [] -> ok;
        [Entry] ->
            ets:delete(?DEDUP_TAB, Key),
            push_aggregated(Host, Entry)
    end.

push_aggregated(Host, #dedup_entry{count = Count, first_packet = Packet,
                                   from = From, to = To}) ->
    case gen_mod:get_module_opt(Host, ?MODULE, push_async) of
        true  -> async_push(Host, From, To, Packet, Count);
        false -> do_push_message(Host, From, To, Packet, Count)
    end.

dedup_key(From, To) ->
    {jid:encode(jid:remove_resource(jid:tolower(From))),
     jid:encode(jid:remove_resource(jid:tolower(To)))}.

cancel_timer(undefined) -> ok;
cancel_timer(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.

%%====================================================================
%% Body 处理
%%====================================================================

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

%%====================================================================
%% HTTP 推送
%%====================================================================

ensure_httpc_profile() ->
    case inets:start(httpc, [{profile, ?HTTPC_PROFILE}]) of
        {ok, _Pid} ->
            httpc:set_options(
                [{max_sessions, 32},
                 {max_keep_alive_length, 100},
                 {keep_alive_timeout, 60000},
                 {pipeline_timeout, 0}],
                ?HTTPC_PROFILE),
            ok;
        {error, {already_started, _}} -> ok;
        Other ->
            ?ERROR_MSG("启动 httpc profile 失败: ~p", [Other]),
            ok
    end.

%% @doc 执行推送（含重试）
%% Count: 合并的消息条数（dedup 场景 >= 1）
do_push_message(Host, From, To, Packet, Count) ->
    PushUrl    = gen_mod:get_module_opt(Host, ?MODULE, push_url),
    Timeout    = gen_mod:get_module_opt(Host, ?MODULE, push_timeout),
    ConnTo     = gen_mod:get_module_opt(Host, ?MODULE, push_connect_timeout),
    ApiKey     = gen_mod:get_module_opt(Host, ?MODULE, push_api_key),
    RetryMax   = gen_mod:get_module_opt(Host, ?MODULE, push_retry),

    PushData = build_push_data(From, To, Packet, Count),
    push_with_retry(PushUrl, PushData, ApiKey, Timeout, ConnTo, RetryMax, 0).

build_push_data(From, To, #message{
    id = Id, type = Type, body = Body,
    subject = Subject, thread = Thread
}, Count) ->
    BodyText = extract_body_text(Body),
    SubjectText = extract_subject_text(Subject),
    Base = #{
        <<"type">>          => <<"offline_message">>,
        <<"from">>          => jid:encode(From),
        <<"to">>            => jid:encode(To),
        <<"to_user">>       => To#jid.luser,
        <<"to_server">>     => To#jid.lserver,
        <<"message_type">>  => atom_to_binary(Type, utf8),
        <<"body">>          => BodyText,
        <<"aggregated_count">> => Count,
        <<"timestamp">>     => erlang:system_time(second)
    },
    D1 = put_optional(<<"message_id">>, Id, Base),
    D2 = put_optional(<<"subject">>, SubjectText, D1),
    put_optional(<<"thread">>, Thread, D2).

put_optional(_K, undefined, Map) -> Map;
put_optional(_K, <<>>, Map) -> Map;
put_optional(K, V, Map) -> Map#{K => V}.

%% @doc 带指数退避 + 抖动的重试
push_with_retry(_Url, PushData, _Key, _T, _CT, MaxRetry, Attempt)
  when Attempt > MaxRetry ->
    ?ERROR_MSG("推送失败超过最大重试次数 to=~s",
               [maps:get(<<"to">>, PushData, <<"unknown">>)]),
    {error, max_retry_exceeded};
push_with_retry(Url, PushData, Key, Timeout, ConnTo, MaxRetry, Attempt) ->
    case Attempt of
        0 -> ok;
        _ ->
            %% 指数退避 + jitter，避免雷群
            Backoff = (1 bsl (Attempt - 1)) * 500,
            Jitter  = erlang:phash2({self(), Url, Attempt}, 250),
            timer:sleep(Backoff + Jitter),
            ?DEBUG("重试推送 attempt=~p/~p", [Attempt + 1, MaxRetry + 1])
    end,
    case call_push_api(Url, PushData, Key, Timeout, ConnTo) of
        {ok, success} ->
            {ok, success};
        {error, Reason} when Attempt < MaxRetry ->
            ?DEBUG("推送失败，准备重试: ~p", [Reason]),
            push_with_retry(Url, PushData, Key, Timeout, ConnTo,
                            MaxRetry, Attempt + 1);
        {error, Reason} ->
            ?WARNING_MSG("推送最终失败 to=~s reason=~p",
                         [maps:get(<<"to">>, PushData, <<"unknown">>), Reason]),
            {error, Reason}
    end.

call_push_api(PushUrl, PushData, ApiKey, Timeout, ConnTo) ->
    RequestBody = jiffy:encode(PushData),
    Headers = build_headers(ApiKey),
    try
        Result = httpc:request(
                   post,
                   {binary_to_list(PushUrl), Headers,
                    "application/json", RequestBody},
                   [{timeout, Timeout}, {connect_timeout, ConnTo}],
                   [{body_format, binary}],
                   ?HTTPC_PROFILE),
        handle_http_result(Result)
    catch
        Class:Reason:Stack ->
            ?ERROR_MSG("调用推送 API 异常 ~p:~p~n~p", [Class, Reason, Stack]),
            {error, {exception, Class, Reason}}
    end.

build_headers(<<>>) ->
    [{"Content-Type", "application/json"}];
build_headers(Key) when is_binary(Key) ->
    [{"Content-Type", "application/json"},
     {"Authorization", "Bearer " ++ binary_to_list(Key)}].

handle_http_result({ok, {{_, 200, _}, _, ResponseBody}}) ->
    parse_push_response(ResponseBody);
handle_http_result({ok, {{_, StatusCode, _}, _, _}}) ->
    {error, {http_status, StatusCode}};
handle_http_result({error, {failed_connect, _}}) ->
    {error, connection_failed};
handle_http_result({error, timeout}) ->
    {error, timeout};
handle_http_result({error, Reason}) ->
    {error, Reason}.

parse_push_response(ResponseBody) ->
    try
        Response = jiffy:decode(ResponseBody, [return_maps]),
        case maps:get(<<"success">>, Response, undefined) of
            true ->
                {ok, success};
            false ->
                FailReason = maps:get(<<"reason">>, Response, <<"unknown">>),
                {error, {push_failed, FailReason}};
            _ ->
                {error, invalid_response}
        end
    catch
        Class:Reason:_Stack ->
            ?ERROR_MSG("解析推送响应失败 ~p:~p body=~s",
                       [Class, Reason, ResponseBody]),
            {error, parse_error}
    end.
