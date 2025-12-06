# Работа с API Битрикс24

## Способы подключения

### 1. Входящий вебхук (Webhook) - Рекомендуется для начала

Простой способ без OAuth. Создаётся в Битрикс24:
- Приложения → Вебхуки → Добавить вебхук

**URL формат:**
```
https://your-domain.bitrix24.ru/rest/{user_id}/{webhook_token}/
```

**Плюсы:** Просто настроить, не требует сервера
**Минусы:** Ограниченные права, привязан к пользователю

### 2. OAuth 2.0 приложение

Полноценное приложение с авторизацией:
- Developer → Добавить приложение

**Плюсы:** Полные права, refresh tokens
**Минусы:** Сложнее настроить

### 3. Локальное приложение

Для selfhosted Битрикс24.

---

## Основные методы API для задач

### Получение задачи

```http
GET /rest/tasks.task.get?taskId=123
```

**Ответ:**
```json
{
  "result": {
    "task": {
      "id": "123",
      "title": "Название задачи",
      "description": "Описание",
      "priority": "2",
      "status": "2",
      "createdBy": "1",
      "responsibleId": "5",
      "deadline": "2024-02-01T18:00:00+03:00",
      "tags": ["tag1", "tag2"],
      "createdDate": "2024-01-15T10:00:00+03:00"
    }
  }
}
```

### Обновление задачи

```http
POST /rest/tasks.task.update
Content-Type: application/json

{
  "taskId": 123,
  "fields": {
    "DESCRIPTION": "Новое описание",
    "TAGS": ["tag1", "tag2", "new_tag"]
  }
}
```

### Получение списка новых задач

```http
GET /rest/tasks.task.list?filter[>CREATED_DATE]=2024-01-20&filter[STATUS]=2
```

**Параметры фильтрации:**
- `STATUS` - статус задачи (2 = Ждёт выполнения)
- `>CREATED_DATE` - созданы после даты
- `RESPONSIBLE_ID` - исполнитель
- `CREATED_BY` - постановщик

---

## Работа с комментариями

### Добавление комментария

```http
POST /rest/task.commentitem.add
Content-Type: application/json

{
  "TASKID": 123,
  "FIELDS": {
    "POST_MESSAGE": "Текст комментария с **markdown**",
    "AUTHOR_ID": 1
  }
}
```

### Получение комментариев

```http
GET /rest/task.commentitem.getlist?TASKID=123
```

**Ответ:**
```json
{
  "result": [
    {
      "ID": "456",
      "POST_MESSAGE": "Текст комментария",
      "AUTHOR_ID": "1",
      "POST_DATE": "2024-01-20T15:30:00+03:00"
    }
  ]
}
```

---

## Пользователи

### Получение информации о пользователе

```http
GET /rest/user.get?ID=5
```

**Ответ:**
```json
{
  "result": [
    {
      "ID": "5",
      "NAME": "Алексей",
      "LAST_NAME": "Сидоров",
      "EMAIL": "sidorov@company.ru"
    }
  ]
}
```

### Получение текущего пользователя

```http
GET /rest/user.current
```

---

## Уведомления

### Отправка системного уведомления

```http
POST /rest/im.notify.system.add
Content-Type: application/json

{
  "USER_ID": 5,
  "MESSAGE": "Задача #123 готова к работе"
}
```

### Отправка личного сообщения

```http
POST /rest/im.message.add
Content-Type: application/json

{
  "DIALOG_ID": 5,
  "MESSAGE": "Привет! Задача обновлена."
}
```

---

## Webhooks (исходящие)

Для получения событий в реальном времени настройте исходящий вебхук:

### События задач:
- `ONTASKADD` - создана новая задача
- `ONTASKUPDATE` - задача обновлена
- `ONTASKDELETE` - задача удалена
- `ONTASKCOMMENTADD` - добавлен комментарий

### Настройка в n8n:

1. Создайте Webhook node в n8n
2. Скопируйте URL (например: `https://your-n8n.com/webhook/bitrix-tasks`)
3. В Битрикс24: Приложения → Вебхуки → Исходящий вебхук
4. Укажите URL и события

### Формат входящих данных:

```json
{
  "event": "ONTASKADD",
  "data": {
    "FIELDS_BEFORE": {},
    "FIELDS_AFTER": {
      "ID": "123",
      "TITLE": "Новая задача"
    }
  },
  "auth": {
    "domain": "your-domain.bitrix24.ru"
  }
}
```

---

## Лимиты API

| Тип | Лимит |
|-----|-------|
| Запросов в секунду | 2 |
| Запросов в час | 3600 |
| Размер batch запроса | 50 команд |

### Batch запросы

Для оптимизации используйте batch:

```http
POST /rest/batch
Content-Type: application/json

{
  "cmd": {
    "get_task": "tasks.task.get?taskId=123",
    "get_comments": "task.commentitem.getlist?TASKID=123",
    "get_user": "user.get?ID=$result[get_task][result][task][createdBy]"
  }
}
```

---

## Настройка в n8n

### HTTP Request Node

```json
{
  "url": "https://{{$credentials.bitrix24Domain}}/rest/{{$credentials.userId}}/{{$credentials.webhookToken}}/tasks.task.get",
  "method": "GET",
  "qs": {
    "taskId": "{{$json.task_id}}"
  }
}
```

### Credentials (n8n)

Создайте Header Auth credential:
- Name: `Bitrix24 Webhook`
- Сохраните URL вебхука как переменную окружения

---

## Полезные ссылки

- [Документация REST API Битрикс24](https://dev.1c-bitrix.ru/rest_help/)
- [Методы для задач](https://dev.1c-bitrix.ru/rest_help/tasks/index.php)
- [Webhooks](https://dev.1c-bitrix.ru/learning/course/index.php?COURSE_ID=99)
