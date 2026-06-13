# 本地横向扩展验证记录

本文记录 ejabberd SAE 镜像在本地 OrbStack 上进行的几轮验证：单实例功能验证、第二副本验证、无集群横向扩展失败验证、Erlang/ejabberd cluster 成功验证。

目标不是写漂亮报告，而是沉淀事实：哪些能力已经验证，哪些变更是必要条件，SAE 横向扩展真正需要什么。

## 测试结论

### 结论 1：普通多副本不是 XMPP 横向扩展

只启动两个独立 ejabberd 容器，即使它们共享 PostgreSQL 和 Redis，也只能证明：

- 每个副本可以独立启动。
- 每个副本可以独立登录。
- SQL 用户数据可共享。
- Keycloak JWT 认证可在任意副本上工作。
- 自定义模块可在任意副本上工作。

但不能证明在线消息跨副本互通。

实测失败场景：

```text
Alice -> ejabberd-local-stack    端口 16222
Bob   -> ejabberd-local-stack-2  端口 26222
Alice 发消息给 Bob
Bob 未收到实时消息
```

原因：两个节点没有组成 ejabberd cluster，在线 session route 在各自节点本地内存/Mnesia 表里，互相不可见。

### 结论 2：加入 ejabberd cluster 后跨实例实时消息通过

成功场景：

```text
Alice -> ejabberd-cluster-1  端口 36222
Bob   -> ejabberd-cluster-2  端口 46222
Alice 发消息给 Bob
Bob 实时收到
mod_message_filter 也收到审核请求
```

真实输出：

```text
OK cluster cross-instance online message delivered
{
  "verify_to": "cluster_bob_1550@xmpp.narsk.dpdns.org",
  "verify_from": "cluster_alice_1550@xmpp.narsk.dpdns.org/node1",
  "verify_body": "cluster cross hello"
}
```

最终 cluster 状态：

```text
ejabberd-cluster-1:
'ejabberd@ejabberd-cluster-2'
'ejabberd@ejabberd-cluster-1'

ejabberd-cluster-2:
'ejabberd@ejabberd-cluster-1'
'ejabberd@ejabberd-cluster-2'
```

日志确认：

```text
Node :"ejabberd@ejabberd-cluster-2" joined our Mnesia SM tables
Node :"ejabberd@ejabberd-cluster-2" joined our Mnesia S2S tables
```

## 本地测试节点

### 基础服务

```text
ejabberd-local-postgres
  image: postgres:17-alpine
  port: 15432 -> 5432
  purpose: shared SQL storage

ejabberd-local-redis
  image: redis:7-alpine
  port: 16379 -> 6379
  purpose: shared Redis service
```

### 单实例 / 普通双副本测试节点

```text
ejabberd-local-stack
  image: registry.pyramidtip.com/library/ejabberd:local-keycloak-auth-test
  ip: 192.168.107.4
  port: 16222 -> 5222
  node: ejabberd@localhost
  status: healthy

ejabberd-local-stack-2
  image: registry.pyramidtip.com/library/ejabberd:local-keycloak-auth-test
  ip: 192.168.107.5
  port: 26222 -> 5222
  node: ejabberd@localhost
  status: healthy
```

普通双副本验证结果：

```text
OK instance2 Keycloak JWT login
OK cross-instance SQL login: registered on instance1, logged in on instance2
```

但跨实例实时消息失败：

```text
Alice on instance1 -> Bob on instance2
Bob timed out waiting for message
```

### Cluster 测试节点

```text
ejabberd-cluster-1
  image: registry.pyramidtip.com/library/ejabberd:local-keycloak-auth-test
  ip: 192.168.107.6
  port: 36222 -> 5222
  node: ejabberd@ejabberd-cluster-1
  status: healthy

ejabberd-cluster-2
  image: registry.pyramidtip.com/library/ejabberd:local-keycloak-auth-test
  ip: 192.168.107.7
  port: 46222 -> 5222
  node: ejabberd@ejabberd-cluster-2
  status: healthy
```

Cluster 启动关键参数：

```bash
-e ERLANG_COOKIE=cluster_cookie_1234567890
-e ERLANG_OPTS="-proto_dist inet_tcp"
-e ERLANG_NODE_ARG=ejabberd@ejabberd-cluster-1
-e ERLANG_NODE_ARG=ejabberd@ejabberd-cluster-2
```

Join 命令：

```bash
docker exec ejabberd-cluster-2 \
  ejabberdctl join_cluster 'ejabberd@ejabberd-cluster-1'
```

检查命令：

```bash
docker exec ejabberd-cluster-1 ejabberdctl list_cluster
docker exec ejabberd-cluster-2 ejabberdctl list_cluster
```

## 已验证能力清单

### 单实例验证

通过 `scripts/verify_local_stack.py` 验证：

```text
online_chat
message_filter_pass
message_filter_rewrite
message_filter_reject
offline_push
```

### Keycloak JWT 登录验证

真实 Keycloak：

```text
base URL: https://kc.pyramidtip.com
realm: cadoo
client_id: cadoo-backend
username claim: name
```

注意：`cadoo-backend` 是 client_id，不是 realm。

实测：

```text
https://kc.pyramidtip.com/realms/cadoo-backend/.well-known/openid-configuration -> 404
https://kc.pyramidtip.com/realms/cadoo/.well-known/openid-configuration -> 200
```

已验证：

```text
keycloak_jwt_login
```

### 普通双副本验证

已验证：

```text
instance2 Keycloak JWT login
cross-instance SQL login
```

未通过：

```text
cross-instance online message without ejabberd cluster
```

### Cluster 双副本验证

已验证：

```text
cluster membership
cross-instance online message delivery
message_filter callback on cross-instance message
```

## 本轮代码变更点

### 1. 新增 Keycloak auth backend

文件：

```text
sae/auth/ejabberd_auth_keycloak_custom.erl
```

作用：

- XMPP SASL PLAIN 的 password 使用 Keycloak access token。
- 从 JWKS 拉取公钥。
- 使用 `jose` 校验 JWT 签名。
- 校验 issuer、exp、iat。
- 校验 token claim 与 XMPP username 匹配。

当前配置：

```text
KEYCLOAK_BASE_URL=https://kc.pyramidtip.com
KEYCLOAK_REALM=cadoo
KEYCLOAK_JID_FIELD=name
KEYCLOAK_JWKS_CACHE_TTL=3600
```

关键修正：

```text
旧模块使用 jiffy:decode，当前官方 ejabberd 镜像没有 jiffy。
已改成 misc:json_decode。
```

### 2. Dockerfile 编译 auth backend

文件：

```text
sae/Dockerfile
```

变更：

- 复制 `sae/auth/ejabberd_auth_keycloak_custom.erl`。
- 在镜像构建期用 ejabberd release 自带 Erlang 编译。
- 输出到：

```text
/opt/ejabberd-26.04/lib/ejabberd-26.4.0/ebin/ejabberd_auth_keycloak_custom.beam
```

注意：不能用 `find ... | head -1` 找 ebin，曾错误写入 `asn1` ebin。现在固定写入 ejabberd ebin。

### 3. entrypoint 支持认证模式切换

文件：

```text
sae/bin/sae-entrypoint.sh
```

新增环境变量：

```text
AUTH_MODE=sql | keycloak
AUTH_PASSWORD_FORMAT=scram | plain
KEYCLOAK_BASE_URL
KEYCLOAK_REALM
KEYCLOAK_JWKS_URL
KEYCLOAK_ISSUER
KEYCLOAK_JID_FIELD
KEYCLOAK_JWKS_CACHE_TTL
```

渲染结果：

SQL-only：

```yaml
auth_method:
  - sql
auth_password_format: scram
```

Keycloak + SQL fallback：

```yaml
auth_method:
  - keycloak_custom
  - sql
auth_password_format: plain
```

### 4. ejabberd 配置模板支持 AUTH_METHODS

文件：

```text
sae/conf/ejabberd.yml.template
```

变更：

```yaml
auth_method:
${AUTH_METHODS}

auth_password_format: ${AUTH_PASSWORD_FORMAT}
```

### 5. 本地 compose 支持镜像和认证参数注入

文件：

```text
docker-compose.local.yml
local/.env.local.example
```

变更：

- `EJABBERD_IMAGE` 可切换镜像。
- `AUTH_MODE` 可切换 SQL / Keycloak。
- Keycloak 参数可通过 env 注入。

### 6. 验证程序增强

文件：

```text
scripts/verify_local_stack.py
scripts/keycloak_token.py
local/VERIFY.md
```

新增能力：

- 获取 Keycloak token 的辅助脚本。
- verifier 支持 `KEYCLOAK_ACCESS_TOKEN` / `KEYCLOAK_TEST_USERNAME`。
- verifier 可指定容器、XMPP 端口、mock 回调端口，支持测试第二副本。

### 7. Consul 自动 cluster bootstrap

文件：

```text
sae/bin/sae-entrypoint.sh
```

新增能力：

- `CLUSTER_ENABLED=true` 时启用 cluster bootstrap。
- 通过 Consul service catalog 注册自身。
- 通过 Consul KV/session 选举 seed 节点。
- seed 节点获得 `service/ejabberd/<prefix>/seed` 锁。
- joiner 节点读取 seed 并自动执行 `ejabberdctl join_cluster <seed>`。
- join 成功后创建 ready 文件：`/tmp/ejabberd-ready`。
- Consul TTL health 从 critical 切到 passing，并后台续约。

关键环境变量：

```text
CLUSTER_ENABLED=true
CLUSTER_DISCOVERY=consul
CONSUL_HTTP_ADDR=http://local-consul:8500
CONSUL_SERVICE_NAME=ejabberd-bootstrap-cluster
CONSUL_KV_PREFIX=service/ejabberd/bootstrap
CONSUL_CHECK_TTL=30s
CONSUL_HEARTBEAT_INTERVAL=5
CLUSTER_JOIN_RETRIES=20
CLUSTER_JOIN_INTERVAL=3
ERLANG_COOKIE=<shared secret>
ERL_DIST_PORT=4370
```

注意：官方 `ejabberdctl` 中 `ERL_DIST_PORT` 不是“固定 Erlang distribution 端口”的正确入口，它会改变 EPMD 行为并加上 `-start_epmd false`。entrypoint 现在只把它当用户友好别名，实际写入：

```text
FIREWALL_WINDOW=4370-4370
```

这样结果是：

```text
epmd: 4369
ejabberd distribution: 4370
```

本地自动 bootstrap 验证结果：

```text
ejabberd-bootstrap-1:
  ip: 192.168.107.5
  node: ejabberd@ejabberd-bootstrap-1
  epmd: 4369
  dist: 4370

ejabberd-bootstrap-2:
  ip: 192.168.107.6
  node: ejabberd@ejabberd-bootstrap-2
  epmd: 4369
  dist: 4370
```

Consul passing services：

```text
count 2
ejabberd-ejabberd-bootstrap-1 192.168.107.5 4370
  erlang_node=ejabberd@ejabberd-bootstrap-1

ejabberd-ejabberd-bootstrap-2 192.168.107.6 4370
  erlang_node=ejabberd@ejabberd-bootstrap-2
```

自动 join 后 cluster 状态：

```text
ejabberd-bootstrap-1:
'ejabberd@ejabberd-bootstrap-2'
'ejabberd@ejabberd-bootstrap-1'

ejabberd-bootstrap-2:
'ejabberd@ejabberd-bootstrap-1'
'ejabberd@ejabberd-bootstrap-2'
```

跨实例消息验证：

```text
OK consul bootstrap cross-instance online message delivered
{
  "verify_to": "bootstrap_bob_1892@xmpp.narsk.dpdns.org",
  "verify_from": "bootstrap_alice_1892@xmpp.narsk.dpdns.org/node1",
  "verify_body": "consul bootstrap cross hello"
}
```

## SAE 横向扩展要求

如果 SAE 要真正支持 XMPP 横向扩展，不能只设置 replicas=2。

必须满足：

```text
1. 每个实例有唯一且稳定的 ERLANG_NODE
   例如 ejabberd@<pod-hostname>

2. 所有实例使用同一个 ERLANG_COOKIE

3. 实例之间网络互通：
   - 4369 epmd
   - Erlang distribution 端口

4. Erlang distribution 端口要固定
   否则云平台安全组/容器网络难以放行

5. 新实例启动后自动 join_cluster 到已有节点

6. 缩容时处理 leave_cluster / 失效节点清理
```

当前本地测试只证明：镜像具备组成 cluster 的基础能力。SAE 是否能跑 cluster，还取决于 SAE 是否能提供稳定实例名、实例间端口互通、启动发现机制。

## 下一步建议

### 短期

SAE 生产先保持：

```text
Replicas=1
```

理由：单实例已经验证 Keycloak、消息过滤、离线推送；普通多副本会产生在线消息跨副本不可达风险。

### 中期

把 entrypoint 增强为自动 cluster 模式：

```text
CLUSTER_ENABLED=true
ERLANG_COOKIE=<shared secret>
ERLANG_NODE=ejabberd@${HOSTNAME}
ERL_DIST_PORT=4370
CLUSTER_SEED_NODE=ejabberd@<seed-host>
```

启动逻辑：

```text
1. 渲染固定 node/cookie/dist port
2. 启动 ejabberd
3. 如果不是 seed，执行 join_cluster seed
4. 输出 list_cluster
```

### 长期

如果 SAE 无法稳定支持 Erlang cluster 网络，迁移到 ACK/Kubernetes StatefulSet：

```text
StatefulSet stable DNS
headless service
固定 Erlang distribution port
pod lifecycle preStop leave_cluster
```

这才是 XMPP 长连接服务的正路。

## 清理测试容器

如果不再需要保留本地 cluster 现场：

```bash
docker rm -f ejabberd-cluster-1 ejabberd-cluster-2
```

普通第二副本：

```bash
docker rm -f ejabberd-local-stack-2
```
