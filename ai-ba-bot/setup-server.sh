#!/bin/bash
# ============================================
# Установка PostgreSQL для ИИ Бизнес-аналитика
# Запустите на сервере: bash setup-server.sh
# ============================================

set -e

N8N_DIR="/opt/beget/n8n"
DB_DIR="$N8N_DIR/ai-ba-db"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-changeme123}"

echo "🚀 Установка PostgreSQL для ИИ Бизнес-аналитика"
echo "================================================"

# 1. Создаём директорию
echo "📁 Создание директории $DB_DIR..."
mkdir -p "$DB_DIR"
cd "$DB_DIR"

# 2. Создаём docker-compose.yml
echo "📝 Создание docker-compose.yml..."
cat > docker-compose.yml << 'COMPOSE'
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: ai-ba-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ai_ba_bot
      POSTGRES_USER: ai_ba_user
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-changeme123}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ai_ba_user -d ai_ba_bot"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

networks:
  n8n-network:
    external: true
    name: n8n-network

volumes:
  postgres_data:
COMPOSE

# 3. Создаём init.sql
echo "📝 Создание init.sql..."
cat > init.sql << 'SQL'
-- ИИ Бизнес-аналитик: Схема базы данных
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Задачи
CREATE TABLE tasks (
    id SERIAL PRIMARY KEY,
    bitrix_task_id VARCHAR(50) NOT NULL UNIQUE,
    title TEXT,
    description TEXT,
    status VARCHAR(50) DEFAULT 'new',
    completeness_score INTEGER DEFAULT 0,
    task_type VARCHAR(50),
    priority VARCHAR(20),
    creator_id VARCHAR(50),
    creator_name VARCHAR(255),
    responsible_id VARCHAR(50),
    responsible_name VARCHAR(255),
    deadline TIMESTAMP,
    tags JSONB DEFAULT '[]'::jsonb,
    ai_context JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_tasks_bitrix_id ON tasks(bitrix_task_id);
CREATE INDEX idx_tasks_status ON tasks(status);

-- Блокировки
CREATE TABLE task_locks (
    id SERIAL PRIMARY KEY,
    bitrix_task_id VARCHAR(50) NOT NULL,
    lock_type VARCHAR(50) NOT NULL DEFAULT 'processing',
    locked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    execution_id VARCHAR(255),
    UNIQUE(bitrix_task_id, lock_type)
);

CREATE INDEX idx_locks_task_id ON task_locks(bitrix_task_id);
CREATE INDEX idx_locks_expires ON task_locks(expires_at);

-- История взаимодействий
CREATE TABLE interactions (
    id SERIAL PRIMARY KEY,
    bitrix_task_id VARCHAR(50) NOT NULL,
    interaction_type VARCHAR(50) NOT NULL,
    actor_type VARCHAR(20) NOT NULL,
    actor_id VARCHAR(50),
    actor_name VARCHAR(255),
    content TEXT,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_interactions_task_id ON interactions(bitrix_task_id);

-- Вопросы и ответы
CREATE TABLE qa_pairs (
    id SERIAL PRIMARY KEY,
    bitrix_task_id VARCHAR(50) NOT NULL,
    question_text TEXT NOT NULL,
    answer_text TEXT,
    question_category VARCHAR(100),
    is_answered BOOLEAN DEFAULT FALSE,
    asked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    answered_at TIMESTAMP
);

CREATE INDEX idx_qa_task_id ON qa_pairs(bitrix_task_id);

-- Статистика
CREATE TABLE statistics (
    id SERIAL PRIMARY KEY,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    metric_name VARCHAR(100) NOT NULL,
    metric_value NUMERIC DEFAULT 0,
    metadata JSONB DEFAULT '{}'::jsonb,
    UNIQUE(date, metric_name)
);

-- Функции
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tasks_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE FUNCTION try_acquire_lock(
    p_task_id VARCHAR(50),
    p_lock_type VARCHAR(50),
    p_ttl_seconds INTEGER,
    p_execution_id VARCHAR(255)
) RETURNS BOOLEAN AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    DELETE FROM task_locks WHERE expires_at < CURRENT_TIMESTAMP;
    INSERT INTO task_locks (bitrix_task_id, lock_type, expires_at, execution_id)
    VALUES (p_task_id, p_lock_type, CURRENT_TIMESTAMP + (p_ttl_seconds || ' seconds')::INTERVAL, p_execution_id)
    ON CONFLICT (bitrix_task_id, lock_type) DO NOTHING;
    SELECT EXISTS(
        SELECT 1 FROM task_locks
        WHERE bitrix_task_id = p_task_id
        AND lock_type = p_lock_type
        AND execution_id = p_execution_id
    ) INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION release_lock(
    p_task_id VARCHAR(50),
    p_lock_type VARCHAR(50),
    p_execution_id VARCHAR(255)
) RETURNS BOOLEAN AS $$
BEGIN
    DELETE FROM task_locks
    WHERE bitrix_task_id = p_task_id
    AND lock_type = p_lock_type
    AND execution_id = p_execution_id;
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_task_context(p_task_id VARCHAR(50))
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'task', (SELECT row_to_json(t) FROM tasks t WHERE bitrix_task_id = p_task_id),
        'interactions', (
            SELECT jsonb_agg(row_to_json(i) ORDER BY i.created_at)
            FROM interactions i WHERE bitrix_task_id = p_task_id
        ),
        'qa_pairs', (
            SELECT jsonb_agg(row_to_json(q) ORDER BY q.asked_at)
            FROM qa_pairs q WHERE bitrix_task_id = p_task_id
        )
    ) INTO v_result;
    RETURN COALESCE(v_result, '{}'::jsonb);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION increment_stat(
    p_metric VARCHAR(100),
    p_value NUMERIC DEFAULT 1
) RETURNS VOID AS $$
BEGIN
    INSERT INTO statistics (date, metric_name, metric_value)
    VALUES (CURRENT_DATE, p_metric, p_value)
    ON CONFLICT (date, metric_name)
    DO UPDATE SET metric_value = statistics.metric_value + p_value;
END;
$$ LANGUAGE plpgsql;

-- Начальные данные
INSERT INTO statistics (date, metric_name, metric_value) VALUES
    (CURRENT_DATE, 'tasks_processed', 0),
    (CURRENT_DATE, 'questions_asked', 0),
    (CURRENT_DATE, 'answers_received', 0),
    (CURRENT_DATE, 'tasks_completed', 0);
SQL

# 4. Проверяем существование Docker сети
echo "🔗 Проверка Docker сети..."
if ! docker network ls | grep -q "n8n-network"; then
    echo "   Создание сети n8n-network..."
    docker network create n8n-network
fi

# 5. Запускаем PostgreSQL
echo "🐘 Запуск PostgreSQL..."
docker-compose up -d

# 6. Ждём готовности
echo "⏳ Ожидание запуска PostgreSQL..."
sleep 10

# 7. Проверяем подключение
echo "✅ Проверка подключения..."
docker exec ai-ba-postgres psql -U ai_ba_user -d ai_ba_bot -c "SELECT 'PostgreSQL готов!' as status;"

echo ""
echo "================================================"
echo "✅ PostgreSQL успешно установлен!"
echo ""
echo "📋 Данные для n8n Credentials:"
echo "   Type: PostgreSQL"
echo "   Host: ai-ba-postgres (или localhost)"
echo "   Port: 5432"
echo "   Database: ai_ba_bot"
echo "   User: ai_ba_user"
echo "   Password: $POSTGRES_PASSWORD"
echo ""
echo "🔧 Полезные команды:"
echo "   Статус:    docker-compose -f $DB_DIR/docker-compose.yml ps"
echo "   Логи:      docker-compose -f $DB_DIR/docker-compose.yml logs -f"
echo "   Остановка: docker-compose -f $DB_DIR/docker-compose.yml down"
echo "================================================"
