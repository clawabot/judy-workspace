# Memory Maintenance Report — 2026-05-31

**Status:** FAILED — DB unavailable

## Ошибка

Все вызовы `judy-memory` MCP завершились с ошибкой:

```
password authentication failed for user "judy"
```

Затронуты: `memory_list`, `memory_recall` — ни один инструмент не вернул данные.

## Выполнено

- Попытка `memory_list(limit=50)` — ошибка авторизации
- Попытка `memory_recall` — та же ошибка

## Не выполнено

- Поиск дублей
- Удаление устаревших записей
- Обновление фактов
- Подсчёт итоговых записей

## Рекомендации

Проверить PostgreSQL на judy-infra (192.168.3.41):
- Пользователь `judy` существует?
- Пароль для пользователя `judy` корректный?
- Сервис PostgreSQL запущен? (`systemctl status postgresql`)
- MCP-сервер judy-memory — конфиг подключения к БД актуален?

Обслуживание откладывается до восстановления подключения.
