# Phase 6-3 Application End-to-End Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 6-3 spec の Section 2 全 Component を実装、 panicboat application (= monolith + frontend + reverse-proxy) を production-grade end-to-end 動作確認まで持っていく。 platform PR + monorepo PR の 2 PR 体制で同日 merge。

**Architecture:** 2 PR 並行:
- **platform PR** (= panicboat/platform): nginx-sample component 削除 + hydrate cleanup (= 極小)
- **monorepo PR** (= panicboat/monorepo): F1 application code (= migration default 削除) + F2 gruf OpenTelemetry interceptor + F4 terragrunt 環境名 hardcode 除去 + D2 reverse-proxy port 80 統一 + DNS develop.panicboat.net 公開 (= NLB internet-facing + ACM + ExternalDNS)

**Tech Stack:**
- Ruby 4.0.3 + Hanami 2.3 + Gruf gRPC + Sequel ORM + ROM + PostgreSQL 17.4
- Next.js 16 + ConnectRPC (= 既 6-2 で deploy 済、 本 plan で 変更 無し)
- Nginx (= reverse-proxy container)
- OpenTofu 1.11 + Terragrunt + AWS RDS
- Cilium 1.18 + Gateway API + AWS Load Balancer Controller + ExternalDNS + AWS ACM + Route53

---

## Spec との差分 (= 既存実装を反映)

spec PR (= merged) の F1 / F2 記述は brainstorming 時点での想定。 実 monorepo 確認で以下が判明、 本 plan で訂正:

- **F1**: spec L277 で `gem "uuid7"` 追加とあるが、 monolith は **Ruby 4.0.3 + 既 `SecureRandom.uuid_v7` 使用** (= 2 箇所 確認: `slices/trust/repositories/review_repository.rb:14`, `slices/media/use_cases/get_upload_url.rb:12`)。 Ruby 標準で UUIDv7 生成可能、 gem 追加 **不要**。
- **F1**: spec L279 で `lib/types.rb` 修正とあるが、 既存 `lib/types.rb` は dry-types 定義 (= UUIDv7 生成と無関係)、 修正 **不要**。 各 entity の id 生成は use_cases / repositories で `SecureRandom.uuid_v7` を call する pattern を踏襲。
- **F2**: spec L281 で gruf interceptor register を `config/initializers/gruf.rb` とあるが、 monolith の gruf entry point は **`bin/grpc`** (= `Gruf.configure do |c| ... end` 内で `c.interceptors.use(...)` で 既 2 interceptors register 済: AccessLogInterceptor / AuthenticationInterceptor)。 本 plan は `bin/grpc` を modify。
- **F1 / F2 共通**: OTel SDK L1 (= `opentelemetry-sdk` + `opentelemetry-instrumentation-all` + `opentelemetry-exporter-otlp`) は **既 Gemfile + `config/initializers/opentelemetry.rb`** で初期化済 (= `OpenTelemetry::SDK.configure { |c| c.service_name = "monolith"; c.use_all }`)、 追加 setup **不要**。 F2 interceptor は `OpenTelemetry.tracer_provider.tracer("gruf-server")` 直接利用可。

---

## File Structure

### Platform repo (= panicboat/platform、 PR #1)

- Delete: `kubernetes/components/nginx-sample/` (= 全 directory recursive)
- Delete: `kubernetes/manifests/production/nginx-sample/` (= hydrate output、 recursive)
- Modify: `kubernetes/manifests/production/kustomization.yaml` (= `./nginx-sample` 参照行削除)

### Monorepo (= panicboat/monorepo、 PR #2)

**application code (= F1 + F2)**

- Modify: `services/monolith/workspace/config/db/migrate/*.rb` (= 12 migration file、 `default: Sequel.lit("uuidv7()")` / `default: Sequel.function(:uuidv7)` 句削除)
- Create: `services/monolith/workspace/lib/interceptors/opentelemetry_interceptor.rb` (= F2 gruf custom interceptor)
- Modify: `services/monolith/workspace/bin/grpc` (= require_relative + interceptors.use 追加)
- Modify (= 必要時のみ): `services/monolith/workspace/slices/*/use_cases/*.rb` または `slices/*/repositories/*.rb` (= migration default 削除に伴い id 生成 SecureRandom.uuid_v7 を明示する箇所、 既存 unimplemented entity のみ)

**K8s manifests (= D2 + DNS)**

- Modify: `services/reverse-proxy/kubernetes/base/service.yaml` (= port 80 統一 + NLB internet-facing annotation + ExternalDNS hostname + ACM cert ARN)
- Modify: `services/reverse-proxy/kubernetes/base/deployment.yaml` (= containerPort 80)
- Modify: `services/reverse-proxy/kubernetes/base/config/conf.d/cilium-gateway.conf` (= listen 80)
- Modify: `services/reverse-proxy/kubernetes/base/config/conf.d/frontend.conf` (= listen 80 + server_name develop.panicboat.net)
- Modify: `services/reverse-proxy/kubernetes/base/httproute.yaml` (= hostnames develop.panicboat.net + backendRefs.port 80)

**terragrunt (= F4)**

- Modify: `services/monolith/terragrunt/modules/variables.tf` (= db_identifier / db_subnet_group_name / db_security_group_name の 3 variable 追加)
- Modify: `services/monolith/terragrunt/modules/main.tf` (= identifier / aws_security_group.name / aws_db_subnet_group.name の `${var.environment}` interpolation を var 参照に置換)
- Modify: `services/monolith/terragrunt/envs/develop/terragrunt.hcl` (= inputs に db_identifier / db_subnet_group_name / db_security_group_name の値 (= "monolith-develop") 追加)

---

## Tasks

### Task 1: F4 terragrunt module 環境名 hardcode 除去 (= monorepo PR)

**Files:**
- Modify: `services/monolith/terragrunt/modules/variables.tf`
- Modify: `services/monolith/terragrunt/modules/main.tf`
- Modify: `services/monolith/terragrunt/envs/develop/terragrunt.hcl`

**Test:** `terragrunt plan` で resource diff 0 を確認 (= 既 deployed RDS / SG / subnet group に変更が出ないことを保証)

- [ ] **Step 1: variables.tf に 3 variable 追加**

`services/monolith/terragrunt/modules/variables.tf` 末尾に追加:

```terraform
variable "db_identifier" {
  type        = string
  description = "RDS DB instance identifier (= 環境別に envs/{env}/terragrunt.hcl で指定、 module 側で環境名 hardcode しない)"
}

variable "db_subnet_group_name" {
  type        = string
  description = "RDS DB subnet group name (= 環境別、 modules 環境名 hardcode 回避)"
}

variable "db_security_group_name" {
  type        = string
  description = "RDS DB security group name (= 環境別、 modules 環境名 hardcode 回避)"
}
```

- [ ] **Step 2: main.tf の 3 箇所 hardcode を var 参照に置換**

`services/monolith/terragrunt/modules/main.tf` で:

Before:
```terraform
resource "aws_security_group" "monolith_db" {
  name        = "monolith-database-${var.environment}"
  ...
}

resource "aws_db_subnet_group" "monolith" {
  name       = "monolith-${var.environment}"
  ...
}

resource "aws_db_instance" "monolith" {
  identifier     = "monolith-${var.environment}"
  ...
}
```

After:
```terraform
resource "aws_security_group" "monolith_db" {
  name        = var.db_security_group_name
  ...
}

resource "aws_db_subnet_group" "monolith" {
  name       = var.db_subnet_group_name
  ...
}

resource "aws_db_instance" "monolith" {
  identifier     = var.db_identifier
  ...
}
```

- [ ] **Step 3: envs/develop/terragrunt.hcl の inputs に値追加**

`services/monolith/terragrunt/envs/develop/terragrunt.hcl` の `inputs = { ... }` block に追加:

```terraform
inputs = {
  aws_region = include.env.locals.aws_region
  common_tags = merge(
    {
      Environment = include.env.locals.environment
    },
    include.env.locals.additional_tags
  )
  db_identifier          = "monolith-develop"
  db_subnet_group_name   = "monolith-develop"
  db_security_group_name = "monolith-database-develop"
}
```

- [ ] **Step 4: terragrunt plan で diff 0 確認 (= 既 deployed resource に変更が出ない)**

Run:
```bash
cd services/monolith/terragrunt/envs/develop
terragrunt plan
```

Expected: `No changes. Your infrastructure matches the configuration.` (= module 内 hardcode 置換 + envs 側で同一名 指定で既 state と一致)

万一 diff が出る場合: var の値が既 deployed resource 名と完全一致しているか確認、 ずれていれば envs/develop/terragrunt.hcl の値を修正。

- [ ] **Step 5: commit**

```bash
git add services/monolith/terragrunt/modules/variables.tf \
        services/monolith/terragrunt/modules/main.tf \
        services/monolith/terragrunt/envs/develop/terragrunt.hcl
git commit -s -m "refactor(monolith/terragrunt): remove environment name hardcode from module

module 側 (= modules/main.tf) の identifier / SG name / subnet group name から
\${var.environment} interpolation を除去、 全て env 別 envs/{env}/terragrunt.hcl
の inputs で明示。 staging / production env 追加時に module 触らず env 追加のみで
完結する pattern (= Phase 7 Theme A multi-env active 化の前提)。

Validation: terragrunt plan で resource diff 0 確認、 既 deployed RDS / SG /
subnet group に変更なし。"
```

---

### Task 2: F1 monolith migration default uuidv7() 削除 (= monorepo PR)

**Files:**
- Modify: `services/monolith/workspace/config/db/migrate/*.rb` (= 12 file、 `Sequel.lit("uuidv7()")` / `Sequel.function(:uuidv7)` 句削除)
- Modify (= 必要時のみ): `services/monolith/workspace/slices/*/use_cases/*.rb` 等 (= id 生成箇所未実装 entity に `SecureRandom.uuid_v7` 追加)

**Test:** `bundle exec hanami db migrate` で local PostgreSQL に migration 成功 (= `uuidv7()` PostgreSQL function 未定義 environment でも fail せず)

- [ ] **Step 1: 全 migration の uuidv7 default 句を列挙**

Run:
```bash
cd services/monolith/workspace
grep -rn "Sequel\.lit(\"uuidv7" config/db/migrate/
grep -rn "Sequel\.function(:uuidv7)" config/db/migrate/
```

Expected: 12 migration file がリスト (= 各 file 1-2 箇所、 計 14-16 箇所程度)

- [ ] **Step 2: 各 migration から default 句削除**

各 migration で:

Before:
```ruby
column :id, :uuid, default: Sequel.lit("uuidv7()"), null: false
```
または
```ruby
column :id, :uuid, default: Sequel.function(:uuidv7), primary_key: true
```

After:
```ruby
column :id, :uuid, null: false
```
または
```ruby
column :id, :uuid, primary_key: true
```

(= `default:` 句のみ削除、 他 attribute は維持)

12 migration file 全てに対して同 pattern で修正。 sed で一括も可:

```bash
cd services/monolith/workspace/config/db/migrate
# Sequel.lit("uuidv7()") form (前後 comma 含む)
sed -i '' -E 's/, default: Sequel\.lit\("uuidv7\(\)"\)//g; s/default: Sequel\.lit\("uuidv7\(\)"\), //g' *.rb
# Sequel.function(:uuidv7) form
sed -i '' -E 's/, default: Sequel\.function\(:uuidv7\)//g; s/default: Sequel\.function\(:uuidv7\), //g' *.rb
```

- [ ] **Step 3: app code の id 生成箇所を全 table で列挙**

Step 2 で default 削除した migration の table 一覧を取得:

```bash
cd services/monolith/workspace
grep -lE "Sequel\.lit\(\"uuidv7|Sequel\.function\(:uuidv7" config/db/migrate/*.rb 2>/dev/null | \
  xargs -I {} grep -hE "create_table" {} | \
  sed -E 's/.*create_table\([^a-z_]*([a-z_]+).*/\1/' | sort -u
```

Expected: 12 table 名 (= 例: blocks, cast_genres, cast_plans, cast_posts, cast_schedules, comments, follows, likes, media_assets, sms_verifications, trust_reviews, users)

各 table に対応する repository / use_case で id 生成箇所を確認:

```bash
for table in $(...above query...); do
  echo "=== ${table} ==="
  grep -rn "${table}" slices/*/repositories/ slices/*/use_cases/ 2>/dev/null | head -5
done
```

判定:

- **既 OK** (= `SecureRandom.uuid_v7` 使用): `slices/trust/repositories/review_repository.rb:14` (= trust_reviews)、 `slices/media/use_cases/get_upload_url.rb:12` (= media_assets) → 触らない
- **DB default 削除で fail** (= id 生成不在、 INSERT 時 NOT NULL 制約 violation): 該当 repository の create 箇所に `id: SecureRandom.uuid_v7` 追加、 もしくは Sequel ORM の `before_create` hook で auto-generate
- **既 別 mechanism** (= 例: 親 entity の id 経由で生成、 association から決定): 触らない

具体的 add pattern (= 例: blocks repository):

Before:
```ruby
def create(blocker_id:, blocked_id:)
  blocks.insert(blocker_id: blocker_id, blocked_id: blocked_id, created_at: Time.now)
end
```

After:
```ruby
def create(blocker_id:, blocked_id:)
  blocks.insert(
    id: SecureRandom.uuid_v7,
    blocker_id: blocker_id,
    blocked_id: blocked_id,
    created_at: Time.now
  )
end
```

判定で迷う entity は Step 4 の migration test で fail として検出される (= NOT NULL violation)、 fail した entity に対して reactive 追加で OK。

- [ ] **Step 4: local PostgreSQL で migration 成功確認**

Run:
```bash
cd services/monolith/workspace
docker-compose up -d postgres
bundle exec hanami db drop
bundle exec hanami db create
bundle exec hanami db migrate
```

Expected:
- `Sequel migrator: applied migration 20260114003157` 等、 全 migration 成功 log
- `uuidv7()` PostgreSQL function 未定義 environment でも fail せず (= 引き継ぎ #28 解消)

万一 fail する場合: Step 2 で sed が正しく動いたか確認、 残存 default 句を手動修正。

- [ ] **Step 5: commit**

```bash
git add services/monolith/workspace/config/db/migrate/ \
        services/monolith/workspace/slices/  # = Step 3 で修正した repository / use_case
git commit -s -m "fix(monolith/migrate): remove PostgreSQL uuidv7() default to use app-side SecureRandom.uuid_v7

Hanami migration が PostgreSQL uuidv7() function 呼び出しで fail する問題 (=
引き継ぎ #28) を解消。 monolith は Ruby 4.0.3 で SecureRandom.uuid_v7 (= 標準
ライブラリ) を 既 使用しており (= trust/review_repository, media/get_upload_url
等)、 全 entity で同 pattern に統一して app code 側 id 生成に寄せる。

migration default 句を 12 file から削除:
- Sequel.lit(\"uuidv7()\") form: N 箇所
- Sequel.function(:uuidv7) form: M 箇所

PostgreSQL 側に uuidv7() function を install する代替も検討したが、 (1) Ruby
4.0.3 標準で UUIDv7 生成可能、 (2) RDS extension 管理 / version 互換性 / RDS
parameter group の運用 overhead を回避、 の 2 点で app code 統一を採用。

Validation: bundle exec hanami db migrate が local PostgreSQL (= uuidv7()
function 未定義) で成功。"
```

---

### Task 3: F2 gruf custom OpenTelemetry interceptor 実装 (= monorepo PR)

**Files:**
- Create: `services/monolith/workspace/lib/interceptors/opentelemetry_interceptor.rb`
- Modify: `services/monolith/workspace/bin/grpc` (= require + interceptors.use 追加)
- Create: `services/monolith/workspace/spec/lib/interceptors/opentelemetry_interceptor_spec.rb` (= RSpec test)

**Test:** RSpec test で incoming RPC に対し span 生成 + W3C tracecontext propagation 動作確認、 local で `grpcurl` 経由 RPC 投入で Tempo に span 流入確認 (= 統合 test)

- [ ] **Step 1: RSpec test を書く (= 失敗 test、 TDD)**

Create `services/monolith/workspace/spec/lib/interceptors/opentelemetry_interceptor_spec.rb`:

```ruby
require "spec_helper"
require "opentelemetry/sdk"
require_relative "../../../lib/interceptors/opentelemetry_interceptor"

RSpec.describe Interceptors::OpenTelemetryInterceptor do
  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:span_exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:span_processor) { OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(span_exporter) }

  before do
    tracer_provider.add_span_processor(span_processor)
    OpenTelemetry.tracer_provider = tracer_provider
  end

  let(:request) do
    instance_double(
      Gruf::Controllers::Request,
      service_class: double(name: "Identity::V1::IdentityService::Service"),
      method_name: "GetUser",
      active_call: double(metadata: { "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" })
    )
  end

  let(:errors) { Gruf::Error.new }
  subject(:interceptor) { described_class.new(request, errors, {}) }

  it "creates a span with rpc attributes for successful call" do
    interceptor.call { "success" }

    spans = span_exporter.finished_spans
    expect(spans.size).to eq(1)
    expect(spans[0].name).to eq("Identity::V1::IdentityService::Service/GetUser")
    expect(spans[0].kind).to eq(:server)
    expect(spans[0].attributes["rpc.system"]).to eq("grpc")
    expect(spans[0].attributes["rpc.service"]).to eq("Identity::V1::IdentityService::Service")
    expect(spans[0].attributes["rpc.method"]).to eq("GetUser")
    expect(spans[0].attributes["rpc.grpc.status_code"]).to eq(0)
  end

  it "records error span on GRPC::BadStatus" do
    expect {
      interceptor.call { raise GRPC::Unauthenticated.new("auth failed") }
    }.to raise_error(GRPC::Unauthenticated)

    spans = span_exporter.finished_spans
    expect(spans[0].attributes["rpc.grpc.status_code"]).to eq(GRPC::Core::StatusCodes::UNAUTHENTICATED)
    expect(spans[0].status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  end

  it "extracts parent context from W3C tracecontext metadata" do
    interceptor.call { "success" }

    spans = span_exporter.finished_spans
    expect(spans[0].trace_id.unpack1("H*")).to eq("0af7651916cd43dd8448eb211c80319c")
  end
end
```

- [ ] **Step 2: test 失敗確認**

Run:
```bash
cd services/monolith/workspace
bundle exec rspec spec/lib/interceptors/opentelemetry_interceptor_spec.rb
```

Expected: FAIL with `cannot load such file -- ../../../lib/interceptors/opentelemetry_interceptor` (= file 未実装)

- [ ] **Step 3: interceptor 実装**

Create `services/monolith/workspace/lib/interceptors/opentelemetry_interceptor.rb`:

```ruby
# frozen_string_literal: true

require "opentelemetry"
require "gruf"

module Interceptors
  # gruf custom interceptor for OpenTelemetry span generation
  #
  # 各 incoming RPC に対し OTel span を生成、 incoming gRPC metadata から W3C
  # tracecontext を extract して parent context として set。 frontend (= Next.js
  # ConnectRPC client) → monolith (= Ruby gruf gRPC server) の trace を結合。
  #
  # OTel SDK L1 (= config/initializers/opentelemetry.rb) で tracer_provider を
  # init 済、 本 interceptor は OpenTelemetry.tracer_provider.tracer("gruf-server")
  # で tracer を取得して span 生成。
  class OpenTelemetryInterceptor < Gruf::Interceptors::ServerInterceptor
    TRACER_NAME = "gruf-server"

    def call
      tracer = OpenTelemetry.tracer_provider.tracer(TRACER_NAME)
      span_name = "#{request.service_class.name}/#{request.method_name}"

      # Extract W3C tracecontext from incoming gRPC metadata
      carrier = request.active_call.metadata.to_h
      parent_context = OpenTelemetry.propagation.extract(carrier)

      OpenTelemetry::Context.with_current(parent_context) do
        tracer.in_span(span_name, kind: :server) do |span|
          span.set_attribute("rpc.system", "grpc")
          span.set_attribute("rpc.service", request.service_class.name)
          span.set_attribute("rpc.method", request.method_name)

          begin
            result = yield
            span.set_attribute("rpc.grpc.status_code", GRPC::Core::StatusCodes::OK)
            result
          rescue GRPC::BadStatus => e
            span.set_attribute("rpc.grpc.status_code", e.code)
            span.status = OpenTelemetry::Trace::Status.error(e.message)
            raise
          rescue => e
            span.set_attribute("rpc.grpc.status_code", GRPC::Core::StatusCodes::UNKNOWN)
            span.status = OpenTelemetry::Trace::Status.error(e.message)
            raise
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: test pass 確認**

Run:
```bash
cd services/monolith/workspace
bundle exec rspec spec/lib/interceptors/opentelemetry_interceptor_spec.rb
```

Expected: `3 examples, 0 failures`

- [ ] **Step 5: bin/grpc で interceptor register**

`services/monolith/workspace/bin/grpc` の既存 require + Gruf.configure block を修正:

Before (= 既存):
```ruby
require_relative "../lib/interceptors/access_log_interceptor"
require_relative "../lib/interceptors/authentication_interceptor"
...
Gruf.configure do |c|
  c.logger = Hanami.logger
  c.server_binding_url = ENV.fetch("GRPC_BIND_ADDRESS", "0.0.0.0:9001")
  c.interceptors.use(Interceptors::AccessLogInterceptor)
  c.interceptors.use(Interceptors::AuthenticationInterceptor)
end
```

After:
```ruby
require_relative "../lib/interceptors/access_log_interceptor"
require_relative "../lib/interceptors/authentication_interceptor"
require_relative "../lib/interceptors/opentelemetry_interceptor"
...
Gruf.configure do |c|
  c.logger = Hanami.logger
  c.server_binding_url = ENV.fetch("GRPC_BIND_ADDRESS", "0.0.0.0:9001")
  # OpenTelemetry interceptor を最先頭で register (= 後段 interceptor + handler
  # の span を child として include)。
  c.interceptors.use(Interceptors::OpenTelemetryInterceptor)
  c.interceptors.use(Interceptors::AccessLogInterceptor)
  c.interceptors.use(Interceptors::AuthenticationInterceptor)
end
```

- [ ] **Step 6: local 統合 test (= gruf start + grpcurl で test request + span 流入観測)**

Run:
```bash
cd services/monolith/workspace
docker-compose up -d  # = monolith gruf server + Tempo container 起動 (= docker-compose に Tempo / OTel Collector 含まれている前提、 未含なら省略可)
sleep 5

# test request 投入
grpcurl -plaintext -d '{"id":"01234567-89ab-cdef-0123-456789abcdef"}' \
  -H "traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" \
  localhost:9001 identity.v1.IdentityService/GetUser

# monolith log で span 生成確認
docker-compose logs monolith | grep -i opentelemetry
```

Expected:
- grpcurl で response 受信 (= 既 implementation の test request 成功)
- monolith log で OTel span flush log (= "exporting 1 spans" 等)
- ローカル Tempo container 有効なら Tempo UI / API で `service.name=monolith` の trace 確認

万一 span が流れない場合:
- Step 5 の require_relative path 確認
- Gruf.configure の interceptors.use 順序確認 (= OpenTelemetryInterceptor が最先頭か)
- `OpenTelemetry::SDK.configure` (= config/initializers/opentelemetry.rb) が boot 時に呼ばれているか確認 (= Hanami boot で auto-load されるか)

- [ ] **Step 7: commit**

```bash
git add services/monolith/workspace/lib/interceptors/opentelemetry_interceptor.rb \
        services/monolith/workspace/spec/lib/interceptors/opentelemetry_interceptor_spec.rb \
        services/monolith/workspace/bin/grpc
git commit -s -m "feat(monolith): add gruf custom OpenTelemetry interceptor (L2)

Phase 6-3 F2 (= OTel SDK L2)。 既 OTel SDK L1 (= config/initializers/opentelemetry.rb
で OpenTelemetry::SDK.configure + use_all) が rom-sql / pg / net-http 等の standard
instrumentation を auto-attach するが、 gruf gRPC server-side は OTel SDK の sanctioned
instrumentation が 存在しないため (= opentelemetry-instrumentation-all に gruf
非対応)、 custom Gruf::Interceptors::ServerInterceptor で span 生成。

各 incoming RPC に対し:
- OpenTelemetry.tracer_provider.tracer(\"gruf-server\") から span 生成
- span name: <service_class>/<method_name>
- span kind: :server
- span attributes: rpc.system=\"grpc\", rpc.service, rpc.method, rpc.grpc.status_code
- W3C tracecontext propagator で incoming gRPC metadata から parent context 抽出
- GRPC::BadStatus は status_code + status=error 記録

bin/grpc で OpenTelemetryInterceptor を最先頭 register (= 後段 interceptor +
handler の span を child として include)。

Validation: RSpec 3 examples pass (= 正常 + error + trace context propagation)、
local grpcurl で test request 投入で Tempo に span 流入確認。"
```

---

### Task 4: D2 reverse-proxy port 80 統一 (= monorepo PR)

**Files:**
- Modify: `services/reverse-proxy/kubernetes/base/service.yaml`
- Modify: `services/reverse-proxy/kubernetes/base/deployment.yaml`
- Modify: `services/reverse-proxy/kubernetes/base/config/conf.d/cilium-gateway.conf`
- Modify: `services/reverse-proxy/kubernetes/base/config/conf.d/frontend.conf`
- Modify: `services/reverse-proxy/kubernetes/base/httproute.yaml`

**Test:** local kind / k3d で apply 後、 reverse-proxy Pod が port 80 で listen + curl で 200 OK

- [ ] **Step 1: service.yaml の port 8080 → 80**

Before:
```yaml
spec:
  ports:
  - protocol: TCP
    port: 8080
    targetPort: 8080
  type: LoadBalancer
```

After:
```yaml
spec:
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: LoadBalancer
```

- [ ] **Step 2: deployment.yaml の containerPort 8080 → 80**

Before:
```yaml
        ports:
        - containerPort: 8080
```

After:
```yaml
        ports:
        - containerPort: 80
```

- [ ] **Step 3: conf.d/cilium-gateway.conf の listen 8080 → 80**

Before:
```nginx
server {
    listen 8080;
    location / {
        proxy_pass http://cilium_gateway;
        ...
    }
}
```

After:
```nginx
server {
    listen 80;
    location / {
        proxy_pass http://cilium_gateway;
        ...
    }
}
```

- [ ] **Step 4: conf.d/frontend.conf の listen 8080 → 80**

Before:
```nginx
server {
    listen 8080;
    server_name frontend.local;
    ...
}
```

After:
```nginx
server {
    listen 80;
    server_name frontend.local;   # = Task 5 で develop.panicboat.net に変更
    ...
}
```

- [ ] **Step 5: httproute.yaml の backendRefs.port 8080 → 80**

Before:
```yaml
    backendRefs:
    - name: reverse-proxy
      port: 8080
```

After:
```yaml
    backendRefs:
    - name: reverse-proxy
      port: 80
```

- [ ] **Step 6: local k3d / kind で apply + 動作確認**

Run:
```bash
cd services/reverse-proxy
kubectl apply -k kubernetes/overlays/develop  # = 適切な overlay
kubectl rollout status -n default deployment/reverse-proxy
kubectl port-forward -n default svc/reverse-proxy 8080:80
# 別 terminal で
curl -sI http://localhost:8080/ | head -3
```

Expected:
- `HTTP/1.1 200 OK` (= cilium-gateway 経由 OR frontend 経由 routing 成功)

万一 fail する場合:
- nginx container log: `kubectl logs -n default deploy/reverse-proxy nginx`
- listen port 確認: `kubectl exec -n default deploy/reverse-proxy -c nginx -- ss -tlnp`

- [ ] **Step 7: commit**

```bash
git add services/reverse-proxy/kubernetes/base/
git commit -s -m "refactor(reverse-proxy): unify port to 80 across Service / Deployment / nginx / HTTPRoute

D2 (= Phase 6-3 spec)。 reverse-proxy stack の port を 80 で統一:
- Service.spec.ports.port: 8080 → 80
- Service.spec.ports.targetPort: 8080 → 80
- Deployment.containers[0].ports.containerPort: 8080 → 80
- nginx conf.d/*.conf: listen 8080 → 80
- HTTPRoute.backendRefs.port: 8080 → 80

NLB internet-facing で develop.panicboat.net 公開時 (= Task 5) に標準 HTTP port
(= 80) で listen、 ACM cert + NLB TLS termination で 443 → 80 backend 経路を
clean に。

Validation: local k3d で apply、 curl http://localhost:8080 → reverse-proxy Pod
の :80 に forward で 200 OK。"
```

---

### Task 5: DNS develop.panicboat.net 公開 (= monorepo PR)

**Files:**
- Modify: `services/reverse-proxy/kubernetes/base/service.yaml` (= AWS LB Controller annotation 追加)
- Modify: `services/reverse-proxy/kubernetes/base/httproute.yaml` (= hostnames 追加)
- Modify: `services/reverse-proxy/kubernetes/base/config/conf.d/frontend.conf` (= server_name + host header)
- Modify: `services/reverse-proxy/kubernetes/base/config/conf.d/cilium-gateway.conf` (= host header propagation 確認)

**Pre-req**: AWS ACM cert (= `develop.panicboat.net`, ap-northeast-1) 発行済 + Route53 hosted zone (= `panicboat.net`) で ExternalDNS が触れる状態。 未満たしなら Step 1-2 で setup。

**Test:** `dig develop.panicboat.net` で Route53 ALIAS record auto-create 確認、 `curl -v https://develop.panicboat.net/` で 200 OK + TLS verify (= ACM cert chain valid)

- [ ] **Step 1: AWS ACM cert 確認 / 発行**

既存確認:
```bash
aws acm list-certificates --region ap-northeast-1 \
  --query 'CertificateSummaryList[?DomainName==`develop.panicboat.net`].CertificateArn' \
  --output text
```

存在する場合: ARN を控える。

存在しない場合: 新規発行:
```bash
aws acm request-certificate \
  --domain-name develop.panicboat.net \
  --validation-method DNS \
  --region ap-northeast-1 \
  --tags Key=Project,Value=panicboat Key=Environment,Value=develop
```

→ DNS validation record を Route53 に手動追加 (= AWS Console: ACM → cert → "Create records in Route 53") → cert STATUS が ISSUED になるまで待つ (= 5-10 min)

ARN を控える (= 例: `arn:aws:acm:ap-northeast-1:559744160976:certificate/abc123-...`)

- [ ] **Step 2: Route53 hosted zone + ExternalDNS 設定確認**

```bash
# Route53 zone 確認
aws route53 list-hosted-zones --query 'HostedZones[?Name==`panicboat.net.`]'

# ExternalDNS の watch namespace + domain filter 確認
kubectl get deploy -n external-dns external-dns -o yaml | grep -A 5 "args:"
```

Expected: ExternalDNS の `--domain-filter` に `panicboat.net` が含まれる。 含まれない場合は platform 側で ExternalDNS config 更新が必要 (= 別 PR、 本 plan の scope 外、 issue として記録)。

- [ ] **Step 3: service.yaml に annotation 追加 (= NLB internet-facing + ACM + ExternalDNS)**

Before (= Task 4 後の state):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: reverse-proxy
spec:
  selector:
    app: reverse-proxy
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: LoadBalancer
```

After:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: reverse-proxy
  annotations:
    # NLB internet-facing で develop.panicboat.net を公開
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    # ACM cert で TLS termination
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:ap-northeast-1:559744160976:certificate/<ARN-from-Step-1>"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "tcp"
    # ExternalDNS で Route53 ALIAS record auto-create
    external-dns.alpha.kubernetes.io/hostname: "develop.panicboat.net"
spec:
  selector:
    app: reverse-proxy
  ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 80
  - name: https
    protocol: TCP
    port: 443
    targetPort: 80     # = TLS termination は NLB で済む、 backend は 80 plain
  type: LoadBalancer
```

NOTE: `<ARN-from-Step-1>` は Step 1 で取得した ACM cert ARN に置換。

- [ ] **Step 4: httproute.yaml に hostnames 追加 + port 80**

Before (= Task 4 後の state):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reverse-proxy
spec:
  parentRefs:
  - name: cilium-gateway
    namespace: default
  hostnames: []
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: reverse-proxy
      port: 80
```

After:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reverse-proxy
spec:
  parentRefs:
  - name: cilium-gateway
    namespace: default
  hostnames:
  - develop.panicboat.net
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: reverse-proxy
      port: 80
```

- [ ] **Step 5: nginx conf.d/frontend.conf の server_name + host header 更新**

Before (= Task 4 後の state):
```nginx
upstream frontend {
    server frontend.default.svc.cluster.local:80;
}

server {
    listen 80;
    server_name frontend.local;

    location / {
        proxy_pass http://frontend;
        proxy_set_header Host $host;
        ...
    }
}
```

After:
```nginx
upstream frontend {
    server frontend.default.svc.cluster.local:80;
}

server {
    listen 80;
    server_name develop.panicboat.net;

    location / {
        proxy_pass http://frontend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

- [ ] **Step 6: cluster apply (= Flux 経由) + NLB / ACM / Route53 紐付け確認**

monorepo PR merge 後、 Flux が `clusters/develop` の reverse-proxy Kustomization を reconcile して service 更新が cluster apply される。

確認 (= eks-production cluster):
```bash
# Service 確認 (= NLB hostname assign 済)
kubectl get svc -n default reverse-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# 例 output: a1b2c3d4e5f6-abc.elb.ap-northeast-1.amazonaws.com

# NLB 確認 (= AWS Console / CLI)
aws elbv2 describe-load-balancers --region ap-northeast-1 \
  --query 'LoadBalancers[?contains(DNSName,`a1b2c3d4e5f6`)].{Name:LoadBalancerName,Scheme:Scheme,State:State.Code}'
# 期待: Scheme=internet-facing, State=active

# Route53 ALIAS record auto-create 確認
dig +short develop.panicboat.net
# 期待: NLB の IP address が返る (= ExternalDNS が ALIAS record を create 済)

# ExternalDNS log 確認
kubectl logs -n external-dns deploy/external-dns --tail=30 | grep develop.panicboat.net
```

- [ ] **Step 7: curl HTTPS test**

```bash
curl -v https://develop.panicboat.net/ 2>&1 | head -30
```

Expected:
- TLS handshake 成功 (= ACM cert chain valid)
- `HTTP/1.1 200 OK` または `HTTP/2 200`
- response body (= frontend Next.js のトップページ HTML)

万一 fail する場合:
- TLS handshake fail → ACM cert ARN annotation 確認、 cert STATUS=ISSUED 確認
- 503 / 502 → reverse-proxy Pod の nginx error log: `kubectl logs -n default deploy/reverse-proxy -c nginx --tail=20`
- DNS resolution fail → Route53 record 確認 / ExternalDNS reconcile 確認

- [ ] **Step 8: commit**

```bash
git add services/reverse-proxy/kubernetes/base/
git commit -s -m "feat(reverse-proxy): expose develop.panicboat.net via NLB internet-facing + ACM

Phase 6-3 DNS。 application を internet から develop.panicboat.net で access 可能に:

- Service annotations:
  - NLB internet-facing (= aws-load-balancer-scheme: internet-facing)
  - ACM cert TLS termination on :443 (= aws-load-balancer-ssl-cert)
  - ExternalDNS Route53 ALIAS record auto-create
- HTTPRoute hostnames: develop.panicboat.net 追加 (= Cilium Gateway L7 routing)
- nginx conf.d/frontend.conf: server_name + host header を develop.panicboat.net に

internet-facing NLB の TLS termination + plain HTTP backend (= reverse-proxy
nginx :80 → frontend :80) で、 cluster 内 mTLS は Cilium Hubble 経路で別途 管理。

Validation: dig develop.panicboat.net で NLB IP resolve、 curl https://develop.panicboat.net/
で 200 OK + TLS verify pass。"
```

---

### Task 6: Platform PR nginx-sample 削除 (= platform PR)

**Files:**
- Delete: `kubernetes/components/nginx-sample/` (= recursive)
- Delete: `kubernetes/manifests/production/nginx-sample/` (= recursive)
- Modify: `kubernetes/manifests/production/kustomization.yaml` (= `./nginx-sample` 行削除)

**Post-merge manual operation:** AWS Secrets Manager `panicboat/nginx/demo` secret を手動 delete (= 引き継ぎ #34)

**Test:** Flux reconcile 後 cluster で nginx-sample 関連 resource が消えていることを確認

- [ ] **Step 1: kubernetes/components/nginx-sample/ 削除**

```bash
cd /Users/takanokenichi/GitHub/panicboat/platform
rm -rf kubernetes/components/nginx-sample/
```

- [ ] **Step 2: kubernetes/manifests/production/nginx-sample/ 削除**

```bash
rm -rf kubernetes/manifests/production/nginx-sample/
```

- [ ] **Step 3: kustomization.yaml から nginx-sample 行削除**

`kubernetes/manifests/production/kustomization.yaml` から `- ./nginx-sample` 行を削除。

Before:
```yaml
resources:
  ...
  - ./mimir
  - ./nginx-sample
  - ./oauth2-proxy
  ...
```

After:
```yaml
resources:
  ...
  - ./mimir
  - ./oauth2-proxy
  ...
```

- [ ] **Step 4: make hydrate-index で再 generate確認 (= manifests/production/ 整合性)**

```bash
cd kubernetes
make hydrate-index ENV=production
```

Expected: `kubernetes/manifests/production/kustomization.yaml` から `./nginx-sample` が消える + 他 component に影響なし

- [ ] **Step 5: git status で削除が正常か確認**

```bash
cd ..
git status --short kubernetes/components/nginx-sample/ kubernetes/manifests/production/nginx-sample/ kubernetes/manifests/production/kustomization.yaml
```

Expected: 全 file が `D` (deleted) または kustomization.yaml が `M` (modified)

- [ ] **Step 6: PR merge 後の cluster 観測**

PR merge 後、 Flux Kustomization `flux-system` が reconcile + prune で nginx-sample 関連 resource を cluster から削除。

```bash
# (= cluster で確認)
kubectl get all -n default -l app=nginx-sample
```

Expected: `No resources found`

- [ ] **Step 7: AWS Secrets Manager secret 手動削除 (= 引き継ぎ #34)**

PR merge 後の 1 回限り manual operation:
```bash
aws secretsmanager delete-secret \
  --secret-id panicboat/nginx/demo \
  --force-delete-without-recovery \
  --region ap-northeast-1
```

これは IaC 外の operation (= secret value は terragrunt scope 外で manual 管理の設計)、 PR closure doc に記録。

- [ ] **Step 8: commit**

```bash
git add kubernetes/
git commit -s -m "chore(eks): remove nginx-sample component (= Phase 5-2 demo finalized)

Phase 5-2 で deploy した nginx-sample (= 13 checklist validation 用 demo
component) は Phase 6-3 application stack (= monolith + frontend + reverse-proxy)
で代替されたため削除:

- kubernetes/components/nginx-sample/ (= source values + helmfile)
- kubernetes/manifests/production/nginx-sample/ (= hydrated manifests)
- kubernetes/manifests/production/kustomization.yaml (= resources 行)

Flux Kustomization flux-system が reconcile + prune で cluster 上の nginx-sample
resource を自動削除。 AWS Secrets Manager の panicboat/nginx/demo secret は IaC
外の manual operation で削除 (= 引き継ぎ #34、 PR closure doc に記録)。"
```

---

### Task 7: 13 checklist application 化 validate (= 観測 + reactive fix)

**Files:** (none) cluster 観測のみ、 検出 latent issue は fix forward PR で resolve。

**Test:** spec の "Component 13 checklist application 化" Section の 15 item を application stack (= monolith + frontend + reverse-proxy) で再 validate、 全 item pass まで loop。

- [ ] **Step 1: cluster で 13 checklist 各 item を順次確認**

spec Section 2 "Component 13 checklist application 化" の 1-15 を実行:

1. **Pod 起動 + Cilium chaining mode IP**: `kubectl get po -n default -o wide` で application 3 Pods (= monolith / frontend / reverse-proxy) が Running、 IP が cilium chaining mode の範囲
2. **ClusterIP Service DNS resolution**: monolith pod 内から `nslookup frontend.default.svc.cluster.local` 等で解決確認
3. **Ingress → ALB / NLB**: Task 5 で deploy 済 NLB の status:loadBalancer.ingress.hostname 確認
4. **external-dns → Route53**: Task 5 Step 6 で確認済の dig develop.panicboat.net
5. **ACM HTTPS**: Task 5 Step 7 で確認済の curl https
6. **HPA cpu 50% scale**: `kubectl get hpa -n default` で HPA 存在確認 (= 実際の scale-up test は load test 不実施、 mechanism 確認のみ)
7. **KEDA ScaledObject Prometheus scale**: `kubectl get scaledobject -n default` で existence 確認
8. **Karpenter node 増加**: 既 deploy 済、 mechanism 確認のみ
9. **Hubble L3/L4/L7 flow**: `hubble observe --namespace default` で application traffic flow 確認
10. **Beyla traces → Tempo**: Tempo で `service.name=frontend` / `service.name=reverse-proxy` / `service.name=nginx` の trace 流入確認 (= monolith は Beyla 対象外、 OTel SDK で別経路)
11. **Loki logs**: Loki で `{service_name="monolith"}` / `{service_name="frontend"}` / `{service_name="reverse-proxy"}` log 流入確認
12. **Mimir metrics + Grafana dashboard**: Grafana で application RED metrics (= `http_server_request_duration_seconds`) 表示確認
13. **ESO secret env 注入**: monolith pod env で DATABASE_URL 等が ESO 経由で注入確認
14. **Reloader rollout**: AWS Secrets Manager の panicboat/monolith/database を rotation → monolith pod auto-rollout 確認
15. **Grafana 認証ゲート**: oauth2-proxy 経由 grafana.panicboat.net access 確認

- [ ] **Step 2: latent issue 別 category 整理**

各 item で fail した場合の cause を 5-1 L1 / 5-1 L2 / 5-2 L1 / 5-2 L2 / 6-1 / 6-2 / 6-3 の pattern category に分類、 record。

- [ ] **Step 3: latent issue は fix forward PR で resolve**

5-1 L2 / 5-2 L1 pattern (= "観測中に検出した latent issue は別 PR で fix forward") に従い、 検出 latent issue を別 PR で resolve。 完了後 Step 1 から再 validate。

- [ ] **Step 4: 全 item pass まで loop**

Step 1-3 を 全 item pass するまで繰り返す。

- [ ] **Step 5: 結果を 6-3 closure doc 用 record**

Phase 6 closure doc (= Phase 6 完了後の別 PR で作成、 spec L381 参照) 用の record として、 13 checklist の pass 状況 + latent issue resolve history を整理。

---

### Task 8: post-flight 7 連続 validate (= 観測 + reactive fix)

**Files:** (none) cluster 観測のみ。

**Test:** spec の "Component post-flight 7 連続 validate" Section に従い、 Section 1-4 の post-flight check を実行、 latent issue は fix forward で resolve。 4-3 / 5-1 / 5-2 / 6-1 / 6-2 / 6-2 fix forward chain / 6-3 の 7 連続 validate 達成。

- [ ] **Step 1: Section 1 (= 既 deploy 済 component health)**

Phase 1-5 + 6-1 + 6-2 で deploy 済 component (= Cilium / Karpenter / cert-manager / external-dns / external-secrets / Flux / KEDA / Mimir / Tempo / Loki / Prometheus / Grafana / Beyla / OTel Collector / Reloader) の health 確認:

```bash
kubectl get po -A | grep -v Running | grep -v Completed | head -20
kubectl get kustomization -A
kubectl get gitrepository -A
```

Expected: 全 Pod Running、 全 Kustomization Ready=True、 GitRepository 最新 sha fetched。

- [ ] **Step 2: Section 2 (= 既 deploy 済 application)**

Phase 6-2 で deploy 済 application (= monolith / frontend / reverse-proxy) の health 確認、 6-3 で新規追加 service annotation / HTTPRoute hostnames が反映済か確認 (= Task 4 / 5 結果)。

- [ ] **Step 3: Section 3 (= 6-3 追加 component health)**

F1 (= monolith migration) / F2 (= gruf interceptor span 流入) / F4 (= terragrunt env-decoupled) / DNS (= develop.panicboat.net 公開) / D2 (= port 80 統一) を再 validate。

- [ ] **Step 4: Section 4 (= latent issue 検出)**

Section 1-3 で 検出した latent issue を category 別 record、 別 PR で fix forward。 完了後 Step 1 から再 validate。

- [ ] **Step 5: 7 連続達成と record**

4-3 / 5-1 / 5-2 / 6-1 / 6-2 / 6-2 fix forward chain / 6-3 の 7 連続 validate 達成を Phase 6 closure doc 用に record。

---

## Plan summary

| Task | PR | Estimated time | TDD applicable |
|---|---|---|---|
| 1. F4 terragrunt | monorepo | 15-30 min | No (= terragrunt plan diff 0 で代替) |
| 2. F1 migration default 削除 | monorepo | 30-60 min | No (= local migration 成功で代替) |
| 3. F2 gruf interceptor | monorepo | 1-2 h | Yes (= RSpec) |
| 4. D2 port 80 統一 | monorepo | 30 min | No (= local apply + curl) |
| 5. DNS 公開 | monorepo | 1-2 h (= ACM 発行待ち含む) | No (= cluster 観測) |
| 6. nginx-sample 削除 | platform | 15-30 min | No (= cluster prune 観測) |
| 7. 13 checklist validate | (cluster) | 1-2 h (+ latent fix) | No |
| 8. post-flight validate | (cluster) | 1-2 h (+ latent fix) | No |

**Total**: 5-10 h (= latent issue fix forward 含む)

**Critical path**: Task 1-6 を並行可能だが、 同 file 触る task は順序あり:
- Task 4 → Task 5 (= reverse-proxy service.yaml + conf.d 同 file)
- Task 6 (= platform PR) は独立、 並行可

**PR merge 順序**:
1. monorepo PR (= Task 1-5) を draft で作成 + review
2. platform PR (= Task 6) を draft で作成 + review
3. 両 PR 同日 merge
4. Task 7-8 を cluster で実行
