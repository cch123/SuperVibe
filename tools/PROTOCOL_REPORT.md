# Vibing 通信协议分析报告

> 基于 2026-04-10 MITM 抓包分析，目标：`wss://vibing-api-*.b02.azurefd.net/ws/pipeline`

---

## 1. 架构概览

Vibing 客户端同时使用 **两条通道** 与同一个服务器通信：

| 通道 | 协议 | 用途 |
|------|------|------|
| WebSocket | `wss://.../ws/pipeline` | 主通道：流式音频上传 + 流式结果接收 |
| HTTP POST | `https://.../api/pipeline` | 备份/并行通道：一次性发送完整音频(base64)，SSE 返回结果 |

两条通道针对**同一次语音输入**同时发起，服务端哪个先返回就用哪个（HTTP 通道的 `done.timing` 中 `gpt_events.cache_hit=true, inflight=true` 表明服务端识别到是同一个请求并复用了 WS 通道的 GPT 结果）。

---

## 2. WebSocket 协议详解

### 2.1 连接生命周期

```
Client                              Server
  │                                    │
  │──── WS Connect ───────────────────>│
  │──── hello ────────────────────────>│
  │──── start (config + screenshot) ──>│
  │──── binary audio chunk ×N ────────>│
  │──── stop ─────────────────────────>│
  │                                    │
  │<─── asr_delta (中间识别结果) ───────│
  │<─── asr_done  (最终识别结果) ───────│
  │<─── gpt_delta ×N (流式翻译/润色) ──│
  │<─── gpt_done  (翻译/润色完成) ─────│
  │<─── screenshot_done (截屏分析) ────│
  │<─── done (总结 + 完整计时) ────────│
  │                                    │
  │──── WS Close ─────────────────────>│
```

每次语音操作都是一个**独立的 WS 连接**（连接→交互→关闭），不复用。

### 2.2 客户端消息

#### `hello` — 握手
```json
{
  "type": "hello",
  "device_id": "FBAC570B-4309-41D3-81B0-9BC81802EF05",
  "client_version": "0.1.0"
}
```
- `device_id`: UUID，持久化在本地，标识设备
- `client_version`: 客户端版本

#### `start` — 开始录音会话
```json
{
  "type": "start",
  "config": {
    "sample_rate": 16000,
    "channels": 1,
    "platform": "macOS",
    "screenshot_base64": "<base64 PNG>",
    "hotwords": "word1\nword2\n...",
    "target_language": "en",   // 可选
    "skip_gpt": true           // 可选
  }
}
```

**config 字段说明：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `sample_rate` | int | 是 | 固定 16000 Hz |
| `channels` | int | 是 | 固定 1（单声道）|
| `platform` | string | 是 | 固定 `"macOS"` |
| `screenshot_base64` | string | 是 | 当前屏幕截图的 base64 PNG，约 300KB-570KB |
| `hotwords` | string | 是 | 热词列表，`\n` 分隔（来自屏幕内容/历史/上次截屏分析）|
| `target_language` | string | 否 | 翻译目标语言代码，不传则为纯转录模式 |
| `skip_gpt` | bool | 否 | 为 `true` 时跳过 GPT 润色/翻译，直接输出 ASR 原文 |

**模式对照表（从抓包观察）：**

| 操作模式 | `target_language` | `skip_gpt` | 效果 |
|----------|-------------------|------------|------|
| 纯转录（润色） | 不传 | 不传/false | ASR → GPT 润色 → 输出 |
| 纯转录（原始） | 不传 | true | ASR → 直接输出，GPT elapsed=0 |
| 翻译（智能润色）| `"en"`/`"ja"`/... | 不传/false | ASR → GPT 翻译+润色 → 流式输出（能理解口误/自我纠正等语境）|
| 翻译（直译） | `"en"`/`"ja"`/... | true | ASR → GPT 直译 → 流式输出（逐字翻译，不做语义润色）|

> **注意**: `skip_gpt` 的含义因模式而异：
> - 纯转录时：`skip_gpt=true` 完全跳过 GPT，elapsed=0，直接返回 ASR 原文
> - 翻译时：`skip_gpt=true` 仍调用 GPT 做翻译（因为翻译必须经过 LLM），但跳过智能润色环节。效果是逐字直译，不会理解自我纠正等语境。同时服务端不返回 `done` 计时消息

#### 音频数据 — Binary 帧
- 格式：**PCM 16-bit LE，16kHz，单声道**
- 每帧固定 **3200 字节**（= 100ms 音频，16000 × 2bytes × 0.1s）
- 录音期间连续发送，约 10 帧/秒

#### `stop` — 停止录音
```json
{
  "type": "stop",
  "client_stop_sent": 1775796389.445
}
```
- `client_stop_sent`: Unix 时间戳（秒，小数），客户端发出 stop 的精确时刻，用于服务端计算延迟

### 2.3 服务端消息

#### `asr_delta` — ASR 中间结果
```json
{
  "type": "asr_delta",
  "text": "嗯，我今天不去上班了。"
}
```
- 语音识别的中间/部分结果，客户端可实时展示

#### `asr_done` — ASR 最终结果
```json
{
  "type": "asr_done",
  "text": "嗯，我今天不去上班了。",
  "elapsed": 0.35,
  "raw_json": {
    "segments": [
      {
        "id": 0,
        "start_time": "0.0",
        "end_time": "2.7",
        "speaker": "0",
        "text": "嗯，我今天不去上班了。",
        "start": 0.0,
        "end": 2.7
      }
    ],
    "language": "zh",
    "duration": 2.7,
    "raw_response_text": "[{\"Start\":0.0,\"End\":2.7,...}]\n"
  }
}
```

| 字段 | 说明 |
|------|------|
| `text` | 最终识别文本 |
| `elapsed` | ASR 后端耗时（秒）|
| `raw_json.segments` | 分段信息：时间戳、说话人、文本 |
| `raw_json.language` | 检测到的语言（如 `"zh"`）|
| `raw_json.duration` | 音频总时长（秒）|

#### `gpt_delta` — GPT 流式翻译/润色片段
```json
{
  "type": "gpt_delta",
  "text": "今日は"
}
```
- 逐片段流式返回，类似 OpenAI 的 SSE streaming
- 纯转录模式（`skip_gpt=true`）不会发送此消息

#### `gpt_done` — GPT 翻译/润色完成
```json
{
  "type": "gpt_done",
  "text": "今日は出勤しません。",
  "elapsed": 1.905
}
```
- `text`: 完整的翻译/润色结果
- `elapsed`: GPT 处理耗时；若 `skip_gpt=true`，elapsed=0 且 text 直接等于 ASR 原文

#### `screenshot_done` — 截屏分析完成
```json
{
  "type": "screenshot_done",
  "analysis": "{\"current_app\":{\"name\":\"微信\",\"status\":\"正在查看群聊消息\",...}}",
  "hotwords": ["微信", "golang runtime阅读", "ThinkInAI", ...],
  "elapsed": 7.267,
  "status": "finished_but_missed_everything"
}
```

| 字段 | 说明 |
|------|------|
| `analysis` | JSON 字符串，包含当前应用名称、状态、上下文描述 |
| `hotwords` | 从截图中提取的热词数组，下次请求时客户端会带上 |
| `elapsed` | 截屏分析耗时（通常 5-15 秒，较慢）|
| `status` | 截屏分析状态。`finished_but_missed_everything` 表示分析完成但 ASR/GPT 已经结束 |

截屏分析是**异步并行**的：它和 ASR/GPT 同时进行，通常完成较晚（5-15s vs ASR 0.3-0.5s），所以它的热词主要用于**下一次**请求。

#### `done` — 会话完成总结
```json
{
  "type": "done",
  "total_elapsed": 2.459,
  "timing": {
    "total": 2.459,
    "encode": 0.0,
    "asr": 0.46,
    "gpt": 1.716,
    "screenshot": 6.283,
    "screenshot_status": "finished_but_missed_everything",
    "asr_events": {
      "mode": "ws",
      "asr_backend": "ws://localhost:8012",
      "end_sent": 0.0,
      "first_partial": 0.743,
      "first_send": 0.743,
      "ws_final": 0.743,
      "partial_count": 1,
      "backend_elapsed": 0.46,
      "_zero": "server_received_stop"
    },
    "gpt_events": {
      "first_token": 1.489,
      "first_content": 1.712,
      "first_send": 1.712,
      "backend_done": 1.716,
      "token_count": 17,
      "prompt_tokens": 820,
      "completion_tokens": 27,
      "cache_hit": false,
      "hash": "737272a5...",
      "prompt_build_done": 0.0,
      "_zero": "asr_done_sent"
    },
    "screenshot_events": {
      "image_base64_len": 290792,
      "payload_size": 294501,
      "request_id": "c5ca4282-...",
      "http_status": 200,
      "analysis_len": 725,
      "hotword_count": 8,
      "prompt_tokens": 1633,
      "completion_tokens": 300,
      "cache_hit": false,
      "hash": "56103441..."
    },
    "gpt_context_source": "win_context_only",
    "asr_hotword_source": "client_only",
    "client_stop_sent": 1775796628.537,
    "server_stop_received": 1775796628.662,
    "server_asr_done_sent": 1775796629.405,
    "server_done_sent": 1775796631.123
  }
}
```

**timing 核心字段：**

| 字段 | 说明 |
|------|------|
| `total` | 从服务端收到 stop 到发出 done 的总耗时 |
| `asr` | ASR 后端处理耗时 |
| `gpt` | GPT 翻译/润色耗时（skip_gpt 时为 0）|
| `screenshot` | 截屏分析耗时 |
| `asr_events.mode` | ASR 通道模式：`"ws"`（WebSocket 流式）或 `"http"`（HTTP 批量）|
| `asr_events.asr_backend` | ASR 后端地址（`ws://localhost:8012` 或 `http://localhost:8013`）|
| `asr_events.partial_count` | ASR 部分结果数量 |
| `gpt_events.token_count` | GPT 输出 token 数 |
| `gpt_events.prompt_tokens` | GPT prompt token 数 |
| `gpt_events.cache_hit` | 是否命中缓存（同一内容重复翻译时可命中）|
| `gpt_events.hash` | 请求内容哈希，用于缓存去重 |
| `gpt_context_source` | GPT 上下文来源：`"win_context_only"` / `"skipped"` |
| `asr_hotword_source` | 热词来源：`"client_only"` |
| `screenshot_events.image_base64_len` | 截图 base64 长度 |
| `screenshot_events.cache_hit` | 截图分析是否命中缓存 |
| `_zero` | 各计时组的零点参考事件 |

---

## 3. HTTP POST 备份通道

### 请求
```
POST /api/pipeline HTTP/1.1
Content-Type: application/json

{
  "device_id": "FBAC570B-...",
  "audio_pcm_base64": "<完整音频 PCM 的 base64>"
}
```
- 录音结束后，客户端将完整音频一次性 base64 编码发送
- 与 WS 通道**同时**发起，作为冗余

### 响应 (SSE)
```
HTTP/1.1 200 OK
Content-Type: text/event-stream

data: {"type": "asr_delta", "text": "..."}
data: {"type": "asr_done", "text": "...", "elapsed": 1.657, ...}
data: {"type": "gpt_done", "text": "...", "elapsed": 0.0}
data: {"type": "done", "total_elapsed": 1.658, "timing": {...}}
```

**与 WS 通道的区别：**

| 对比项 | WebSocket 通道 | HTTP POST 通道 |
|--------|---------------|----------------|
| 音频传输 | 流式 binary 帧 (3200B/帧) | 一次性 base64 |
| ASR 后端 | `ws://localhost:8012` | `http://localhost:8013` |
| ASR 模式 | `mode: "ws"` | `mode: "http"` |
| 结果返回 | 独立 WS 消息 | SSE data 行 |
| GPT 流式 | 有 `gpt_delta` | 仅 `gpt_done`（因为 WS 通道已在处理）|
| GPT 缓存 | 首次处理 | 通常 `cache_hit=true, inflight=true` |
| 截屏分析 | 包含 | 无（`screenshot: null`）|

---

## 4. 服务端架构推断

从 `done.timing` 中可推断服务端内部架构：

```
                    ┌─ ASR Backend (ws://localhost:8012)  ← WS 流式
Client ─── Pipeline Server ─┤
                    │  ASR Backend (http://localhost:8013) ← HTTP 批量
                    ├─ GPT Backend (LLM，翻译/润色)
                    └─ Screenshot Analyzer (视觉模型，分析截屏)
```

- **Pipeline Server**: Azure Front Door 后的主服务，编排所有子服务
- **ASR**: 两个后端（WS 流式 + HTTP 批量），同时使用
- **GPT**: 负责翻译/润色，支持 prompt 缓存和去重（hash）
- **Screenshot Analyzer**: 独立的视觉分析服务，异步执行，结果用于下一轮的热词

---

## 5. 翻译机制详解

### 5.1 触发方式
- `config.target_language` 设为语言代码（如 `"en"`, `"ja"`）即触发翻译
- 不设置则为纯转录（可能带润色或 skip_gpt 跳过）

### 5.2 翻译流程
1. ASR 完成后，服务端将 ASR 文本 + 截屏上下文组装为 GPT prompt
2. GPT 流式生成翻译结果，逐片段通过 `gpt_delta` 返回
3. 翻译完成后发 `gpt_done`，包含完整翻译文本和耗时

### 5.3 四种 GPT 处理模式

| 模式 | 条件 | GPT 行为 | 示例 |
|------|------|----------|------|
| 润色 | 无 target_language, 无 skip_gpt | 修正口语/标点，无需修改时原样返回 | `"Hello，你好，哎。"` → `"Hello，你好，哎。"` |
| 跳过 | 无 target_language, skip_gpt=true | 完全不调 GPT，elapsed=0 | ASR 原文直出 |
| 智能翻译 | 有 target_language, 无 skip_gpt | 翻译 + 语义润色（理解口误/自我纠正）| 见 5.4 |
| 直译 | 有 target_language, skip_gpt=true | 仅翻译，不做语义润色 | `"嗯，我今天不去上班了。"` → `"今日は出勤しません。"` |

### 5.4 智能翻译 vs 直译对比

**智能翻译** (`target_language="ja"`, 无 skip_gpt):
- 原文: `"哎，我今天要去打游戏，所以不去上班了。哎，不对，我要去医院，所以不去上班了。"`
- 翻译: `"あー、今日は病院に行くので、仕事には行きません。"`
- GPT 理解了"不对"是自我纠正，只翻译了最终意图（去医院），自动去掉了"打游戏"的口误

**直译** (`target_language="ja"`, `skip_gpt=true`):
- 原文: `"嗯，我今天不去上班了。"`
- 翻译: `"今日は出勤しません。"`
- 逐字翻译，不做额外语义理解

> 两种模式的另一个差异：智能翻译模式服务端会返回完整的 `done` 计时消息；直译模式不返回 `done`

---

## 6. 热词系统

### 6.1 来源
1. **客户端本地**: 从 `data/hotwords.txt` 读取 + 屏幕可见文字
2. **截屏分析**: `screenshot_done.hotwords` 返回的热词数组
3. 下一次请求时，客户端合并这两个来源发送到 `config.hotwords`

### 6.2 用途
- 提高 ASR 对特定词汇的识别准确度（如专有名词、代码术语）
- 示例热词: `"SuperVibe"`, `"ws_spy.py"`, `"golang runtime"`, `"Vibing"`, `"Whisper"`

---

## 7. 性能数据

| 指标 | 典型值 |
|------|--------|
| ASR 延迟 | 0.35 - 0.47 秒 |
| GPT 翻译延迟 | 1.7 - 1.9 秒 |
| GPT 首 token | ~1.5 秒 |
| GPT 润色（无需修改）| 0 秒（直接返回）|
| 截屏分析延迟 | 5 - 15 秒 |
| 端到端总延迟 | 2.0 - 2.5 秒（不含截屏）|
| 音频帧大小 | 3200 字节 / 100ms |
| 截图大小 | 290KB - 570KB (base64) |
