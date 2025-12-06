# Руководство по настройке ИИ Бизнес-аналитика

## Предварительные требования

- [ ] Selfhosted n8n (версия >= 1.0)
- [ ] Доступ к Битрикс24 с правами администратора
- [ ] API ключ для LLM (OpenAI, Anthropic или Ollama)
- [ ] (Опционально) PostgreSQL для хранения состояния

---

## Шаг 1: Настройка Битрикс24

### 1.1 Создание входящего вебхука

1. Войдите в Битрикс24 под администратором
2. Перейдите: **Приложения → Разработчикам → Другое → Входящий вебхук**
3. Нажмите **Добавить вебхук**
4. Выберите права:
   - `task` - Задачи
   - `user` - Пользователи
   - `im` - Сообщения

5. Скопируйте URL вебхука:
   ```
   https://your-domain.bitrix24.ru/rest/1/abc123xyz/
   ```

### 1.2 Создание исходящего вебхука (для событий)

1. Перейдите: **Приложения → Разработчикам → Другое → Исходящий вебхук**
2. Нажмите **Добавить вебхук**
3. URL обработчика: `https://your-n8n-domain.com/webhook/bitrix-tasks`
4. Выберите события:
   - `ONTASKADD`
   - `ONTASKUPDATE`
   - `ONTASKCOMMENTADD`
5. Сохраните

### 1.3 Создание бота (опционально)

Для отправки сообщений от имени бота:

1. Приложения → Добавить приложение → Чат-бот
2. Настройте бота с именем "ИИ Бизнес-аналитик"
3. Сохраните credentials

---

## Шаг 2: Настройка n8n

### 2.1 Переменные окружения

Добавьте в `.env` или docker-compose:

```env
# Битрикс24
BITRIX24_WEBHOOK_URL=https://your-domain.bitrix24.ru/rest/1/abc123xyz/
BITRIX24_DOMAIN=your-domain.bitrix24.ru

# OpenAI
OPENAI_API_KEY=sk-...

# Или Anthropic
ANTHROPIC_API_KEY=sk-ant-...

# Или Ollama (локальный)
OLLAMA_URL=http://localhost:11434
```

### 2.2 Создание Credentials в n8n

1. Откройте n8n → Settings → Credentials
2. Создайте **Header Auth**:
   - Name: `Bitrix24`
   - Value: (пустое, URL будет в переменных)

3. Создайте **OpenAI** (или HTTP Header для Anthropic):
   - API Key: ваш ключ

### 2.3 Импорт Workflow

1. Скопируйте содержимое `workflows/ai-ba-main.json`
2. n8n → Workflows → Import from File
3. Вставьте JSON
4. Настройте credentials в каждом node

---

## Шаг 3: Настройка Workflow

### 3.1 Webhook Node (входная точка)

- **HTTP Method:** POST
- **Path:** `bitrix-tasks`
- **Authentication:** None (или Basic если нужно)

### 3.2 HTTP Request Nodes (Битрикс24)

Замените URL на переменную:
```
{{$env.BITRIX24_WEBHOOK_URL}}tasks.task.get?taskId={{$json.task_id}}
```

### 3.3 AI Node (OpenAI или HTTP Request)

**Для OpenAI:**
- Model: `gpt-4-turbo-preview`
- Temperature: 0.3
- System Prompt: содержимое из `prompts/task-analyzer.md`

**Для Anthropic (через HTTP Request):**
```json
{
  "url": "https://api.anthropic.com/v1/messages",
  "method": "POST",
  "headers": {
    "x-api-key": "{{$env.ANTHROPIC_API_KEY}}",
    "anthropic-version": "2023-06-01",
    "content-type": "application/json"
  },
  "body": {
    "model": "claude-3-5-sonnet-20241022",
    "max_tokens": 1024,
    "messages": [...]
  }
}
```

---

## Шаг 4: Тестирование

### 4.1 Ручной тест

1. Активируйте workflow
2. Создайте тестовую задачу в Битрикс24 с неполным описанием
3. Проверьте логи n8n
4. Убедитесь, что комментарий с вопросами появился

### 4.2 Проверка цепочки

| Шаг | Ожидаемый результат |
|-----|---------------------|
| 1. Создание задачи | Webhook получает событие |
| 2. Получение данных | API возвращает задачу |
| 3. Анализ ИИ | JSON с оценкой полноты |
| 4. Генерация вопросов | Текст вопросов |
| 5. Комментарий | Комментарий в задаче |

### 4.3 Отладка

Включите подробное логирование:
```env
N8N_LOG_LEVEL=debug
```

Просматривайте execution history в n8n.

---

## Шаг 5: Production настройки

### 5.1 Error Handling

Добавьте Error Trigger workflow:
1. При ошибке → отправка в Telegram/Slack
2. Retry логика для API вызовов
3. Fallback на альтернативную LLM

### 5.2 Rate Limiting

Добавьте задержки между запросами к Битрикс24:
```javascript
// В Function Node
await new Promise(resolve => setTimeout(resolve, 500));
```

### 5.3 Мониторинг

Рекомендуемые метрики:
- Количество обработанных задач
- Среднее время обработки
- Процент задач с уточнениями
- Ошибки API

### 5.4 Backup

Регулярно экспортируйте workflows:
```bash
n8n export:workflow --all --output=/backup/workflows.json
```

---

## Типичные проблемы

### "401 Unauthorized" от Битрикс24

- Проверьте URL вебхука
- Убедитесь, что токен не истёк
- Проверьте права вебхука

### "429 Too Many Requests"

- Добавьте задержки между запросами
- Используйте batch запросы
- Увеличьте интервал polling

### LLM возвращает невалидный JSON

- Добавьте `response_format: {"type": "json_object"}`
- Используйте JSON mode в OpenAI
- Добавьте try/catch и retry

### Комментарий не появляется в задаче

- Проверьте права на комментирование
- Убедитесь, что AUTHOR_ID валидный
- Проверьте формат POST_MESSAGE

---

## Полезные ресурсы

- [n8n Документация](https://docs.n8n.io/)
- [Битрикс24 REST API](https://dev.1c-bitrix.ru/rest_help/)
- [OpenAI API](https://platform.openai.com/docs/)
- [Anthropic API](https://docs.anthropic.com/)
