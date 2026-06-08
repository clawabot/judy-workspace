# Пиздатая память для Джуди — Архитектурный аудит

**Клава, синьор инженер** | 2026-06-08 04:35 МСК

---

## Диагноз текущей архитектуры

### Три параллельных пайплайна — никто никого не видит

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  memory-core    │     │  judy-memory MCP │     │  Nightly Cron   │
│  (OpenClaw)     │     │  (кастомный)     │     │  (agentTurn)    │
├─────────────────┤     ├──────────────────┤     ├─────────────────┤
│ SQLite + файлы  │     │ Postgres+pgvector│     │ 9 фаз ночью     │
│ MEMORY.md       │     │ CouchDB/Obsidian │     │ пытается всё    │
│ memory/*.md     │     │ Redis            │     │ синхронизировать│
└───────┬─────────┘     └────────┬─────────┘     └────────┬────────┘
        │                        │                        │
        ▼                        ▼                        ▼
  memory_search            MCP tools              Ручная консолидация
  (автоматически)       (explicit calls)        (раз в сутки)
        │                        │                        │
        └────────────────────────┴────────────────────────┘
                                 │
                          НЕТ единой точки входа
                          НЕТ общего retrieval
```

**Суть проблемы**: Active Memory (плагин OpenClaw) автоматически вызывает `memory_search` перед каждым ответом. Это ОЧЕНЬ круто — память инжектится в контекст без явного запроса. Но `memory_search` видит ТОЛЬКО файлы (MEMORY.md, memory/*.md). 17+ записей в pgvector с эмбеддингами multilingual-e5-base — НЕ участвуют в этом retrieval.

---

## 🔴 Проблема 1: Postgres — password authentication failed

### Root Cause

В docker-compose.yml:
```yaml
postgres:
  environment:
    POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
```

Пароль юзера `judy` берётся из `.env` файла. Postgres в Docker **устанавливает пароль только при первом создании базы** (когда том `postgres-data` пустой). Но:

1. Если контейнер пересоздаётся (docker compose down/up), а том сохранился — пароль в томе не меняется
2. Если `.env` файл потерялся/изменился — новое значение `${POSTGRES_PASSWORD}` НЕ совпадает с тем что в томе
3. `pg_hba.conf` внутри контейнера регенерируется при каждом старте, но auth method зависит от `POSTGRES_HOST_AUTH_METHOD` (не задан → default `scram-sha-256`)

**Наиболее вероятная причина**: `.env` файл с новым/другим паролем, а в томе Postgres старый пароль. Или .env вообще не подхватился при docker compose up.

### Решение

```bash
# Шаг 1: Узнать текущий пароль из ENV MCP контейнера
docker exec judy-mcp env | grep POSTGRES_PASSWORD

# Шаг 2: Попробовать с этим паролем
docker exec judy-postgres psql -U judy -d judy -c "SELECT 1"

# Шаг 3: Если не работает — сбросить пароль через admin
docker exec judy-postgres psql -U admin -d judy -c \
  "ALTER USER judy PASSWORD 'НОВЫЙ_ПАРОЛЬ';"

# Шаг 4: Прописать этот пароль в .env
echo "POSTGRES_PASSWORD=НОВЫЙ_ПАРОЛЬ" >> /opt/judy-infra/.env

# Шаг 5: Пересоздать MCP контейнер с новым паролем
docker compose up -d mcp
```

### Как сделать стабильным (prevent recurrence)

1. **Добавить в docker-compose.yml для Postgres:**
```yaml
environment:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-JudySecr3tP4ss}
  # Явный default — если .env потерялся, пароль не сломается
```

2. **Создать скрипт healthcheck-восстановления** `/opt/judy-infra/scripts/fix-postgres.sh`:
```bash
#!/bin/bash
# Вызывается из крона или main агента при ошибке
PASS=$(docker exec judy-mcp env | grep POSTGRES_PASSWORD | cut -d= -f2)
docker exec judy-postgres psql -U judy -d judy -c "SELECT 1" 2>/dev/null && exit 0

# Не получилось — пробуем через admin
docker exec judy-postgres psql -U admin -d judy -c \
  "ALTER USER judy PASSWORD '$PASS';" 2>/dev/null && echo "FIXED"
```

3. **В MCP сервер добавить retry с backoff:**
```python
# Вместо прямого asyncpg.connect(PG_DSN)
from tenacity import retry, stop_after_attempt, wait_exponential

@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=1, max=10))
async def _pg_connect():
    return await asyncpg.connect(PG_DSN)
```

---

## 🟡 Проблема 2: Active Memory не видит pgvector

### Текущее состояние

```json5
// openclaw.json
"active-memory": {
  "config": {
    "model": "deepseek/deepseek-v4-flash",
    "queryMode": "recent",
    // NO toolsAllow → sub-agent only calls memory_search/memory_get
    // NO promptAppend → no instruction to query MCP
  }
}
```

Active Memory sub-agent вызывает только `memory_search` (индексация файлов). Он НЕ знает про существование `mcp__judy-memory__memory_recall`.

### Решение: Prompt Append + Tools Allow (подтверждено документацией)

OpenClaw Active Memory **явно поддерживает** этот паттерн. Из исходников (`docs/concepts/active-memory.md`):

> "The blocking memory sub-agent can use only the configured memory recall tools.
> By default that is: `memory_search`, `memory_get`.
> **Set `config.toolsAllow` when another memory provider exposes a different recall tool contract.**"

И:

> "Use `promptAppend` with custom `toolsAllow` when a non-core memory plugin needs
> provider-specific tool order or query-shaping instructions."

**Конфигурация для `openclaw.json`:**

```json5
"active-memory": {
  "enabled": true,
  "config": {
    "enabled": true,
    "agents": ["main"],
    "allowedChatTypes": ["direct"],
    "model": "deepseek/deepseek-v4-flash",
    "queryMode": "recent",
    "promptStyle": "balanced",
    "timeoutMs": 15000,
    "maxSummaryChars": 220,
    // ↓ КЛЮЧЕВЫЕ СТРОКИ ↓
    "toolsAllow": [
      "mcp__judy-memory__memory_recall"
    ],
    "promptAppend": "Также используй mcp__judy-memory__memory_recall с query на основе последних сообщений — это долгосрочная векторная память в Postgres. Если MCP-сервер не отвечает (ошибка), просто пропусти и используй результаты memory_search. Объедини результаты из обоих источников в единый контекст."
  }
}
```

**Как это работает**:
- `toolsAllow` добавляет `mcp__judy-memory__memory_recall` к стандартным `memory_search` + `memory_get`
- `promptAppend` инструктирует sub-agent делать ДВА запроса и объединять результаты
- Если MCP не отвечает — sub-agent пропускает и использует только файловую память (graceful degradation)
- Таймаут 15s покрывает оба запроса с запасом

**Latency impact**: ~200-500ms дополнительно (MCP SSE round-trip до judy-infra:8716). В пределах 15s timeout нормально.

**Важно**: `mcp__judy-memory__memory_recall` уже возвращает `"(nothing found)"` при отсутствии результатов. Это корректно для паттерна "return NONE on weak connection" из документации.

### Альтернативный подход: Memory Proxy

Если `toolsAllow` не работает как ожидается, можно сделать тонкую прослойку — memory-proxy MCP tool, который атомарно делает два запроса:

```python
@mcp.tool()
async def memory_recall_unified(query: str, limit: int = 5) -> str:
    """Search BOTH vector memory and return combined context."""
    # 1. pgvector search (уже есть)
    pg_results = await _pg_recall(query, limit)
    # 2. Файловый search через OpenClaw API
    # 3. Merge + return
```

Но это сложнее и требует доступа к OpenClaw API. Первый подход (`toolsAllow` + `promptAppend`) — проще и элегантнее.

---

## 🟡 Проблема 3: Ночной крон — фазы пропускаются

### Текущий статус

Крон в 3:00 МСК, 9 фаз, 600s timeout. Две из трёх последних ночей — Postgres мёртв → фазы 2,4,5,7 пропущены.

### Исправления

1. **Pre-flight check в начале payload крона:**
```
Перед началом фаз:
1. Вызови mcp__judy-memory__memory_list(limit=1) — проверка Postgres
2. Вызови mcp__judy-memory__obsidian_list() — проверка CouchDB
3. Если Postgres не отвечает — выполни скрипт восстановления:
   exec(command="ssh root@192.168.3.41 'docker exec judy-postgres pg_isready'", timeout=30)
   При ошибке — exec(command="ssh root@192.168.3.41 'bash /opt/judy-infra/scripts/fix-postgres.sh'")
4. Если восстановить не удалось — выполни ТОЛЬКО Obsidian-фазы и запиши alert в отчёт
```

2. **Увеличить timeout до 900s** (если Postgres работает, 600s маловато для 9 фаз с embedding вызовами)

3. **Использовать deepseek-v4-flash для крона**: дешевле, быстрее, достаточно для memory ops. Сейчас используется сессионная модель (deepseek-v4-pro или Sonnet).

```bash
# В cron payload добавить model override
"model": "deepseek/deepseek-v4-flash"
```

4. **Разделить крон на два:**
   - `memory-consolidation` (3:00 МСК, 10 мин) — только Postgres консолидация + дедупликация
   - `memory-reflection` (3:15 МСК, 10 мин) — Obsidian структурирование + ассоциации + дневник

   Это снижает риск что одна ошибка убивает весь пайплайн.

---

## 🟡 Проблема 4: Obsidian стабильность

### Диагноз

CouchDB работает (проверили — отвечает). CORS настроен в init.sh. Проблема в **клиентской репликации** (Obsidian LiveSync плагин на стороне Макса) или в **транзиентных ошибках записи**.

### Решения

1. **MCP server: добавить retry в obsidian_write**
```python
@mcp.tool()
def obsidian_write(path: str, content: str) -> str:
    # ... текущий код ...
    r = couch_req("PUT", doc_id, doc)
    if "error" in r:
        # Retry once after 1s
        time.sleep(1)
        r = couch_req("PUT", doc_id, doc)
    return f"written: {path} ({size} bytes)" if r.get("ok") else f"error: {r}"
```

2. **Healthcheck в ночном кроне**: после obsidian_write делать verify — obsidian_read того же path, сравнить первые 100 символов.

3. **CouchDB compaction**: раз в неделю запускать compaction для предотвращения деградации:
```bash
curl -X POST -H "Authorization: Basic ..." \
  "http://192.168.3.41:5984/judy/_compact"
```

4. **Obsidian LiveSync плагин**: убедиться что на клиенте Макса:
   - Endpoint: `http://192.168.3.41:5984/judy`
   - Replication interval: не слишком частый (>30s)
   - Chunk size: дефолтный
   - Периодически делать "Rebuild database" если рассинхрон

---

## Архитектурное решение: Unified Memory Pipeline

### Предлагаемая архитектура

```
┌──────────────────────────────────────────────────────┐
│                   Active Memory                       │
│           (deepseek-v4-flash, 15s timeout)            │
│                                                       │
│  ┌──────────────────┐   ┌─────────────────────────┐  │
│  │  memory_search   │   │ mcp__judy-memory__      │  │
│  │  (файлы/SQLite)  │   │ memory_recall (pgvector)│  │
│  └──────┬───────────┘   └───────────┬─────────────┘  │
│         └──────────┬────────────────┘                 │
│                    ▼                                  │
│            Merged Context → prompt prefix             │
└──────────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────┐
│               Main Agent (v4-pro)                     │
│   AGENTS.md → memory_search + memory_recall           │
│   по мере необходимости                              │
└──────────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────┐
│                  Storage Layer                         │
│                                                       │
│  ┌──────────────┐  ┌────────────┐  ┌──────────────┐  │
│  │  Postgres    │  │  CouchDB    │  │   Redis      │  │
│  │  + pgvector  │  │  (Obsidian) │  │  (session    │  │
│  │  (векторная  │  │  (структур. │  │   context)   │  │
│  │   память)    │  │   заметки)  │  │              │  │
│  └──────────────┘  └────────────┘  └──────────────┘  │
│                                                       │
│  ┌──────────────────────────────────────────────────┐ │
│  │  memory-core (SQLite + файлы)                    │ │
│  │  Автосинхронизация из AGENTS.md → MEMORY.md     │ │
│  │  memory_flush хук сохраняет важное в файлы      │ │
│  └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────┐
│               Nightly Cron (3:00 МСК)                 │
│                                                       │
│  [Pre-check] → [Consolidation Postgres]              │
│  → [Structuring Obsidian] → [Cross-sync]             │
│  → [Associations] → [Tomorrow.md] → [Diary]         │
│  → [Healthcheck report]                              │
│                                                       │
│  + auto-recovery Postgres если упал                  │
│  + 2 раздельных cron job (consolidation + reflection)│
└──────────────────────────────────────────────────────┘
```

### Ключевые принципы

1. **Retrieval-first**: память инжектится автоматически, а не ждёт явного вызова
2. **Single source of truth**: pgvector — главный, Obsidian — структурированное представление, файлы — fallback + быстрый index
3. **Resilience**: каждый компонент может упасть независимо, остальные продолжают работать
4. **Cost-effective**: всё на deepseek, никаких новых сервисов

---

## План внедрения (по приоритету)

### 🔴 Этап 1 — Починить Postgres (сегодня, 10 минут)

- [ ] Выяснить текущий пароль через `docker exec judy-mcp env`
- [ ] Сбросить пароль через admin user если нужно
- [ ] Зафиксировать пароль в `.env` с default-значением в docker-compose.yml
- [ ] Проверить: `docker exec judy-postgres psql -U judy -d judy -c "SELECT count(*) FROM memories"`

### 🟡 Этап 2 — Подключить pgvector к Active Memory (следующий шаг)

- [ ] Добавить `toolsAllow` и `promptAppend` в конфиг active-memory
- [ ] Рестартовать gateway
- [ ] Проверить через `/verbose on` + `/trace on` что sub-agent вызывает memory_recall

### 🟡 Этап 3 — Улучшить ночной крон

- [ ] Добавить pre-flight проверку Postgres + Obsidian
- [ ] Добавить скрипт auto-recovery (`/opt/judy-infra/scripts/fix-postgres.sh`)
- [ ] Разделить на 2 cron job (consolidation + reflection)
- [ ] Увеличить timeout до 900s
- [ ] Перевести на deepseek-v4-flash

### 🟢 Этап 4 — Стабилизировать Obsidian

- [ ] Добавить retry в obsidian_write (MCP server)
- [ ] Добавить verify после записи в ночном кроне
- [ ] Добавить weekly compaction cron job в docker compose

---

## Плюсы и минусы предложенного решения

| Аспект | ✅ Плюсы | ❌ Минусы |
|--------|----------|-----------|
| **toolsAllow + promptAppend** | Без кода, только конфиг. Active Memory видит pgvector. Быстрое внедрение. | Зависит от надёжности MCP-соединения. +200-500ms latency на каждый ретрайвл. |
| **Pre-cron healthcheck** | Фазы не пропускаются молча. Auto-recovery снижает ручное вмешательство. | Усложняет payload cron. Требует SSH-доступа с ClawBot на judy-infra. |
| **Разделение cron** | Ошибка в одной фазе не убивает всё. Лучше параллелится (разные модели). | Два cron job вместо одного. Чуть больше конфигурации. |
| **Retry в obsidian_write** | Снижает transient failures. Минимальное изменение кода. | Маскирует реальные проблемы если их станет много. |
| **Unified retrieval** | Память «просто работает» без явных вызовов. Контекст богаче. | Два retrieval вызова на каждый ответ → чуть медленнее и дороже. |
| **Вся архитектура в целом** | Использует существующую инфру. Никаких новых сервисов. Только deepseek. | Не решает проблему если MCP сервер целиком упадёт (но он на Docker с restart: unless-stopped). |

---

## Что НЕ делаем (антипаттерны)

- ❌ **Mem0 / Zep / сторонние сервисы** — ещё один внешний зависимый сервис, усложнение, затраты
- ❌ **Переезд на другой embedding провайдер** (OpenAI/Gemini) — multilingual-e5-base локально работает, бесплатно, менять незачем
- ❌ **Полный отказ от файловой памяти** — файлы дают быстрый fallback и human-readable формат, это ценно
- ❌ **Крон на каждые 30 минут** — дорого по токенам, избыточно для нашей нагрузки

---

## Резюме

Главная архитектурная проблема — **разрыв между тремя пайплайнами памяти**. Решение элегантное и дёшевое:

1. **Починить Postgres** (10 минут, скрипт fix-postgres.sh)
2. **Подключить pgvector к Active Memory** через `toolsAllow` + `promptAppend` (только конфиг, 5 минут)
3. **Улучшить крон** pre-check + auto-recovery (payload update, 15 минут)
4. **Retry в obsidian_write** (3 строки кода в MCP server)

**Результат**: Джуди реально начинает «видеть» всю свою память (файлы + векторная база) в каждом разговоре, а не только когда Макс явно просит «поищи в памяти». Ночной крон перестаёт молча пропускать фазы. Obsidian пишется стабильно.
