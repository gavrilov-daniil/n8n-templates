-- ИИ Бизнес-аналитик: Схема базы данных
-- PostgreSQL 15+

-- Расширения
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- 1. ЗАДАЧИ (tasks) - основная информация
-- ============================================
CREATE TABLE tasks (
    id SERIAL PRIMARY KEY,
    bitrix_task_id VARCHAR(50) NOT NULL UNIQUE,
    title TEXT,
    description TEXT,
    status VARCHAR(50) DEFAULT 'new',
    -- new, processing, pending_response, ready, completed
    completeness_score INTEGER DEFAULT 0,
    task_type VARCHAR(50),
    -- bug, feature, improvement, research, support
    priority VARCHAR(20),
    creator_id VARCHAR(50),
    creator_name VARCHAR(255),
    responsible_id VARCHAR(50),
    responsible_name VARCHAR(255),
    deadline TIMESTAMP,
    tags JSONB DEFAULT '[]'::jsonb,
    ai_context JSONB DEFAULT '{}'::jsonb,
    -- Контекст для ИИ
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_tasks_bitrix_id ON tasks(bitrix_task_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_created_at ON tasks(created_at);

-- ============================================
-- 2. БЛОКИРОВКИ (task_locks) - для дебаунса
-- ============================================
CREATE TABLE task_locks (
    id SERIAL PRIMARY KEY,
    bitrix_task_id VARCHAR(50) NOT NULL,
    lock_type VARCHAR(50) NOT NULL DEFAULT 'processing',
    -- processing, debounce
    locked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    execution_id VARCHAR(255),
    -- n8n execution ID
    UNIQUE(bitrix_task_id, lock_type)
);

CREATE INDEX idx_locks_task_id ON task_locks(bitrix_task_id);
CREATE INDEX idx_locks_expires ON task_locks(expires_at);

-- ============================================
-- 3. ИСТОРИЯ ВЗАИМОДЕЙСТВИЙ (interactions)
-- ============================================
CREATE TABLE interactions (
    id SERIAL PRIMARY KEY,
    bitrix_task_id VARCHAR(50) NOT NULL,
    interaction_type VARCHAR(50) NOT NULL,
    -- task_created, task_updated, question_asked, answer_received,
    -- description_updated, tags_applied, task_completed
    actor_type VARCHAR(20) NOT NULL,
    -- bot, user, system
    actor_id VARCHAR(50),
    actor_name VARCHAR(255),
    content TEXT,
    -- Текст взаимодействия
    metadata JSONB DEFAULT '{}'::jsonb,
    -- Дополнительные данные
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_interactions_task_id ON interactions(bitrix_task_id);
CREATE INDEX idx_interactions_type ON interactions(interaction_type);
CREATE INDEX idx_interactions_created ON interactions(created_at);

-- ============================================
-- 4. ВОПРОСЫ И ОТВЕТЫ (qa_pairs)
-- ============================================
CREATE TABLE qa_pairs (
    id SERIAL PRIMARY KEY,
    bitrix_task_id VARCHAR(50) NOT NULL,
    question_text TEXT NOT NULL,
    answer_text TEXT,
    question_category VARCHAR(100),
    -- goal, result, context, acceptance_criteria, deadline, etc.
    is_answered BOOLEAN DEFAULT FALSE,
    asked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    answered_at TIMESTAMP
);

CREATE INDEX idx_qa_task_id ON qa_pairs(bitrix_task_id);
CREATE INDEX idx_qa_answered ON qa_pairs(is_answered);

-- ============================================
-- 5. СТАТИСТИКА (statistics)
-- ============================================
CREATE TABLE statistics (
    id SERIAL PRIMARY KEY,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    metric_name VARCHAR(100) NOT NULL,
    metric_value NUMERIC DEFAULT 0,
    metadata JSONB DEFAULT '{}'::jsonb,
    UNIQUE(date, metric_name)
);

CREATE INDEX idx_stats_date ON statistics(date);
CREATE INDEX idx_stats_metric ON statistics(metric_name);

-- ============================================
-- 6. ФУНКЦИИ И ТРИГГЕРЫ
-- ============================================

-- Автообновление updated_at
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

-- Функция: Попытка захватить блокировку
CREATE OR REPLACE FUNCTION try_acquire_lock(
    p_task_id VARCHAR(50),
    p_lock_type VARCHAR(50),
    p_ttl_seconds INTEGER,
    p_execution_id VARCHAR(255)
) RETURNS BOOLEAN AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    -- Удаляем просроченные блокировки
    DELETE FROM task_locks WHERE expires_at < CURRENT_TIMESTAMP;

    -- Пытаемся вставить новую блокировку
    INSERT INTO task_locks (bitrix_task_id, lock_type, expires_at, execution_id)
    VALUES (p_task_id, p_lock_type, CURRENT_TIMESTAMP + (p_ttl_seconds || ' seconds')::INTERVAL, p_execution_id)
    ON CONFLICT (bitrix_task_id, lock_type) DO NOTHING;

    -- Проверяем, наша ли это блокировка
    SELECT EXISTS(
        SELECT 1 FROM task_locks
        WHERE bitrix_task_id = p_task_id
        AND lock_type = p_lock_type
        AND execution_id = p_execution_id
    ) INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- Функция: Освободить блокировку
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

-- Функция: Получить историю задачи для контекста ИИ
CREATE OR REPLACE FUNCTION get_task_context(p_task_id VARCHAR(50))
RETURNS JSONB AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'task', (SELECT row_to_json(t) FROM tasks t WHERE bitrix_task_id = p_task_id),
        'interactions', (
            SELECT jsonb_agg(row_to_json(i) ORDER BY i.created_at)
            FROM interactions i
            WHERE bitrix_task_id = p_task_id
        ),
        'qa_pairs', (
            SELECT jsonb_agg(row_to_json(q) ORDER BY q.asked_at)
            FROM qa_pairs q
            WHERE bitrix_task_id = p_task_id
        )
    ) INTO v_result;

    RETURN COALESCE(v_result, '{}'::jsonb);
END;
$$ LANGUAGE plpgsql;

-- Функция: Обновить статистику
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

-- ============================================
-- 7. НАЧАЛЬНЫЕ ДАННЫЕ
-- ============================================
INSERT INTO statistics (date, metric_name, metric_value) VALUES
    (CURRENT_DATE, 'tasks_processed', 0),
    (CURRENT_DATE, 'questions_asked', 0),
    (CURRENT_DATE, 'answers_received', 0),
    (CURRENT_DATE, 'tasks_completed', 0);

-- Готово!
