# База данных для ИИ Бизнес-аналитика

## Быстрый старт

### 1. Запуск PostgreSQL

```bash
cd /path/to/ai-ba-bot

# Установите пароль (опционально)
export POSTGRES_PASSWORD=your_secure_password

# Запустите PostgreSQL
docker-compose up -d
```

### 2. Проверка подключения

```bash
docker exec -it ai-ba-postgres psql -U ai_ba_user -d ai_ba_bot -c "SELECT 1"
```

### 3. Настройка в n8n

1. Откройте n8n → Settings → Credentials
2. Создайте новые Credentials типа **PostgreSQL**:
   - **Name**: `PostgreSQL BA Bot`
   - **Host**: `localhost` (или IP сервера с PostgreSQL)
   - **Port**: `5432`
   - **Database**: `ai_ba_bot`
   - **User**: `ai_ba_user`
   - **Password**: `changeme123` (или ваш пароль)
   - **SSL**: `Off`

### 4. Добавление нод в workflow

Примеры нод находятся в файле `n8n-postgres-nodes.json`.

Основные ноды:

| Нода | Описание |
|------|----------|
| 🔒 БД: Захватить блокировку | Захват блокировки вместо тега ba_processing |
| 🔓 БД: Освободить блокировку | Освобождение блокировки после обработки |
| 💾 БД: Сохранить задачу | Сохранение задачи в БД |
| 📝 БД: Записать взаимодействие | Логирование действий бота |
| 📚 БД: Получить контекст | Получение истории для ИИ |
| 📊 БД: Обновить статистику | Инкремент счётчиков |

## Схема базы данных

### Таблицы

#### `tasks` — Задачи
- `bitrix_task_id` — ID задачи в Битрикс24
- `title`, `description` — Заголовок и описание
- `status` — Статус обработки (new, processing, pending_response, ready)
- `completeness_score` — Оценка полноты (0-100)
- `task_type` — Тип задачи (bug, feature, etc.)
- `ai_context` — JSON с контекстом для ИИ

#### `task_locks` — Блокировки (для дебаунса)
- `bitrix_task_id` — ID задачи
- `lock_type` — Тип блокировки (processing, debounce)
- `expires_at` — Время истечения
- `execution_id` — ID выполнения n8n

#### `interactions` — История взаимодействий
- `bitrix_task_id` — ID задачи
- `interaction_type` — Тип действия
- `actor_type` — Кто выполнил (bot, user, system)
- `content` — Текст/описание
- `metadata` — Дополнительные данные (JSON)

#### `qa_pairs` — Вопросы и ответы
- `bitrix_task_id` — ID задачи
- `question_text` — Вопрос
- `answer_text` — Ответ
- `is_answered` — Получен ли ответ

#### `statistics` — Статистика
- `date` — Дата
- `metric_name` — Название метрики
- `metric_value` — Значение

### Функции

```sql
-- Захват блокировки (возвращает true если успешно)
SELECT try_acquire_lock('task_id', 'processing', 300, 'execution_id');

-- Освобождение блокировки
SELECT release_lock('task_id', 'processing', 'execution_id');

-- Получение контекста задачи для ИИ
SELECT get_task_context('task_id');

-- Инкремент статистики
SELECT increment_stat('tasks_processed', 1);
```

## Примеры использования

### Использование блокировки вместо тегов

**Вместо:**
```
Задача не обработана? → 🔒 Установить тег ba_processing
```

**Используйте:**
```
🔒 БД: Захватить блокировку → Блокировка получена? → Продолжить обработку
```

### Сохранение истории

После каждого ключевого действия добавляйте ноду `📝 БД: Записать взаимодействие`:

```
ИИ: Анализ полноты → 📝 БД: Записать взаимодействие → Нужны уточнения?
```

### Контекст для ИИ

Перед вызовом ИИ получите полную историю:

```
📚 БД: Получить контекст → ИИ: Анализ с контекстом
```

В промпте ИИ добавьте:
```
История взаимодействий с задачей:
{{ $('📚 БД: Получить контекст').item.json[0].context }}
```

## Мониторинг

### Просмотр статистики

```sql
SELECT * FROM statistics WHERE date = CURRENT_DATE;
```

### Просмотр активных блокировок

```sql
SELECT * FROM task_locks WHERE expires_at > CURRENT_TIMESTAMP;
```

### Просмотр истории задачи

```sql
SELECT * FROM interactions
WHERE bitrix_task_id = '123'
ORDER BY created_at DESC;
```

## Резервное копирование

```bash
# Создание бэкапа
docker exec ai-ba-postgres pg_dump -U ai_ba_user ai_ba_bot > backup.sql

# Восстановление
docker exec -i ai-ba-postgres psql -U ai_ba_user ai_ba_bot < backup.sql
```
