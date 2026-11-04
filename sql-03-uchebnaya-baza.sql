-- =====================================================================
-- Учебная база для учебника по SQL / PostgreSQL
-- Домен: грузоперевозки по Европе (клиенты, перевозки, диспетчеры,
-- водители, грузовики, трекинг, счета и оплаты)
--
-- Запуск одной командой (из папки, где лежит этот файл). Скрипт выполнится
-- сам при первом старте контейнера, база freight создастся автоматически:
--   docker run -d --name pg18 \
--     -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=freight \
--     -p 5432:5432 -v pg18-data:/var/lib/postgresql \
--     -v "$PWD/sql-03-uchebnaya-baza.sql":/docker-entrypoint-initdb.d/seed.sql:ro \
--     postgres:18
--   docker logs -f pg18      # ждать строки «database system is ready to accept connections»
--
-- Пересоздать с нуля:  docker rm -f pg18 && docker volume rm pg18-data, затем команду выше.
--
-- Вручную (как в уроке 1.1), в уже запущенный контейнер:
--   docker exec -it pg18 psql -U postgres -c 'CREATE DATABASE freight'
--   docker cp sql-03-uchebnaya-baza.sql pg18:/tmp/
--   docker exec -it pg18 psql -U postgres -d freight -f /tmp/sql-03-uchebnaya-baza.sql
--
-- Генерация занимает около 20 секунд. Данные детерминированы (setseed),
-- поэтому у всех одинаковые ответы на задачи.
--
-- ВАЖНО: вторичных индексов здесь НЕТ, включая индексы на внешних ключах.
-- Есть только индексы под PRIMARY KEY и UNIQUE. Это намеренно: в главах
-- про индексы и EXPLAIN читатель создаёт их сам и смотрит, как меняется план.
--
-- Что заложено специально (см. урок 1.2):
--   - cities на serial, остальные таблицы на identity;
--   - клиенты 1901–2000, водители 571–600, грузовики 431–450 без истории;
--   - origin_country в shipments дублирует страну города (денормализация);
--   - 0.2 % событий трекинга продублированы;
--   - в invoices три валюты в одной колонке, currency char(3);
--   - порядок колонок в shipments не оптимален для выравнивания.
-- =====================================================================

DROP SCHEMA IF EXISTS freight CASCADE;
CREATE SCHEMA freight;
SET search_path = freight, public;
SET TimeZone = 'UTC';   -- только на время генерации, база от него не зависит

SELECT setseed(0.42);

-- ---------------------------------------------------------------------
-- Справочники
-- ---------------------------------------------------------------------

-- Единственная таблица на serial: для сравнения с identity в уроке 1.4
CREATE TABLE cities (
    id      serial       PRIMARY KEY,
    name    text         NOT NULL,
    country text         NOT NULL CHECK (length(country) = 2),
    region  text         NOT NULL,
    lat     numeric(8,5) NOT NULL,
    lon     numeric(8,5) NOT NULL,
    UNIQUE (name, country)
);

CREATE TABLE customers (
    id           integer       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         text          NOT NULL,               -- имена могут повторяться
    segment      text          NOT NULL CHECK (segment IN ('individual', 'smb', 'enterprise')),
    email        text,                                  -- у ~10 % NULL
    vat_number   text          UNIQUE,                  -- NULL у частных лиц
    city_id      integer       NOT NULL REFERENCES cities (id),
    credit_limit numeric(12,2) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
    is_active    boolean       NOT NULL DEFAULT true,
    created_at   timestamptz   NOT NULL DEFAULT now()
);

-- Иерархия диспетчеров (для рекурсивных CTE):
-- 1 глава → 5 региональных → 12 тимлидов → 30 линейных
CREATE TABLE dispatchers (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  text    NOT NULL,
    manager_id integer REFERENCES dispatchers (id),   -- NULL у главы
    hired_at   date    NOT NULL
);

CREATE TABLE drivers (
    id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name     text    NOT NULL,
    phone         text,                                -- бывает NULL, формат разный
    license_no    text    NOT NULL UNIQUE,
    status        text    NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active', 'on_leave', 'terminated')),
    dispatcher_id integer NOT NULL REFERENCES dispatchers (id),
    hired_at      date    NOT NULL,
    terminated_at date,                                -- NULL = работает
    CHECK (terminated_at IS NULL OR terminated_at >= hired_at),
    CHECK ((status = 'terminated') = (terminated_at IS NOT NULL))
);

CREATE TABLE trucks (
    id          integer  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plate       text     NOT NULL UNIQUE,
    model       text     NOT NULL,
    year_built  smallint NOT NULL,
    capacity_kg integer  NOT NULL CHECK (capacity_kg > 0)   -- зависит от model
);

-- ---------------------------------------------------------------------
-- Основные таблицы
-- ---------------------------------------------------------------------

-- Центр схемы. Порядок колонок намеренно не оптимизирован (глава 8).
CREATE TABLE shipments (
    id             bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id      uuid          NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    customer_id    integer       NOT NULL REFERENCES customers (id),
    status         text          NOT NULL DEFAULT 'created'
                                 CHECK (status IN ('created', 'assigned', 'in_transit',
                                                   'delivered', 'cancelled')),
    dispatcher_id  integer       REFERENCES dispatchers (id),   -- NULL у created
    priority       text          NOT NULL DEFAULT 'standard'
                                 CHECK (priority IN ('standard', 'express', 'critical')),
    origin_city_id integer       NOT NULL REFERENCES cities (id),
    origin_country text          NOT NULL,                      -- дублирует cities.country
    dest_city_id   integer       NOT NULL REFERENCES cities (id),
    weight_kg      integer       NOT NULL CHECK (weight_kg > 0),
    declared_value numeric(12,2) NOT NULL CHECK (declared_value >= 0),
    created_at     timestamptz   NOT NULL DEFAULT now(),
    picked_up_at   timestamptz,
    delivered_at   timestamptz,
    tags           text[]        NOT NULL DEFAULT '{}',
    meta           jsonb         NOT NULL DEFAULT '{}'
);

-- История назначений водитель + грузовик (многие-ко-многим).
-- Текущее назначение — последнее по assigned_at.
CREATE TABLE assignments (
    id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id    bigint      NOT NULL REFERENCES shipments (id) ON DELETE CASCADE,
    driver_id      integer     NOT NULL REFERENCES drivers (id),
    truck_id       integer     NOT NULL REFERENCES trucks (id),
    assigned_at    timestamptz NOT NULL,
    released_at    timestamptz,                    -- NULL = назначение действует
    release_reason text        CHECK (release_reason IN ('reassigned', 'cancelled'))
);

-- Большая append-only таблица (индексы, BRIN, партиционирование, EXPLAIN)
CREATE TABLE tracking_events (
    id          bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id bigint       NOT NULL REFERENCES shipments (id) ON DELETE CASCADE,
    occurred_at timestamptz  NOT NULL,
    event_type  text         NOT NULL CHECK (event_type IN
                               ('pickup', 'gps', 'checkpoint', 'stop', 'delivery')),
    speed_kmh   integer,                           -- NULL у pickup, stop, delivery
    lat         numeric(8,5) NOT NULL,
    lon         numeric(8,5) NOT NULL
);

-- Один счёт на доставленную перевозку
CREATE TABLE invoices (
    id          bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id bigint        NOT NULL UNIQUE REFERENCES shipments (id),
    amount      numeric(12,2) NOT NULL CHECK (amount > 0),
    currency    char(3)       NOT NULL CHECK (currency IN ('EUR', 'PLN', 'CHF')),
    issued_at   date          NOT NULL,
    due_at      date          NOT NULL CHECK (due_at >= issued_at)
);

-- Оплаты: бывают частичные и в две части
CREATE TABLE payments (
    id         bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id bigint        NOT NULL REFERENCES invoices (id),
    amount     numeric(12,2) NOT NULL CHECK (amount > 0),
    paid_at    timestamptz   NOT NULL
);

-- Очередь задач (FOR UPDATE SKIP LOCKED, блокировки, конкурентность)
CREATE TABLE job_queue (
    id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind       text        NOT NULL,
    payload    jsonb       NOT NULL,
    status     text        NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending', 'running', 'done', 'failed')),
    attempts   integer     NOT NULL DEFAULT 0,
    run_after  timestamptz NOT NULL DEFAULT now(),
    locked_by  text,
    locked_at  timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Данные: справочники
-- ---------------------------------------------------------------------

-- 52 города, 24 страны. У шести стран три города и больше.
INSERT INTO cities (name, country, region, lat, lon) VALUES
 ('Berlin',     'DE', 'east',    52.52000,  13.40500),
 ('Hamburg',    'DE', 'north',   53.55110,   9.99370),
 ('Munich',     'DE', 'south',   48.13510,  11.58200),
 ('Cologne',    'DE', 'west',    50.93750,   6.96030),
 ('Frankfurt',  'DE', 'west',    50.11090,   8.68210),
 ('Stuttgart',  'DE', 'south',   48.77580,   9.18290),
 ('Warsaw',     'PL', 'central', 52.22970,  21.01220),
 ('Krakow',     'PL', 'south',   50.06470,  19.94500),
 ('Gdansk',     'PL', 'north',   54.35200,  18.64660),
 ('Wroclaw',    'PL', 'west',    51.10790,  17.03850),
 ('Poznan',     'PL', 'west',    52.40640,  16.92520),
 ('Paris',      'FR', 'central', 48.85660,   2.35220),
 ('Lyon',       'FR', 'south',   45.76400,   4.83570),
 ('Marseille',  'FR', 'south',   43.29650,   5.36980),
 ('Lille',      'FR', 'north',   50.62920,   3.05730),
 ('Milan',      'IT', 'north',   45.46420,   9.19000),
 ('Rome',       'IT', 'central', 41.90280,  12.49640),
 ('Turin',      'IT', 'north',   45.07030,   7.68690),
 ('Bologna',    'IT', 'north',   44.49490,  11.34260),
 ('Madrid',     'ES', 'central', 40.41680,  -3.70380),
 ('Barcelona',  'ES', 'east',    41.38510,   2.17340),
 ('Valencia',   'ES', 'east',    39.46990,  -0.37630),
 ('Amsterdam',  'NL', 'north',   52.36760,   4.90410),
 ('Rotterdam',  'NL', 'west',    51.92440,   4.47770),
 ('Eindhoven',  'NL', 'south',   51.44160,   5.46970),
 ('Brussels',   'BE', 'central', 50.85030,   4.35170),
 ('Antwerp',    'BE', 'north',   51.21940,   4.40250),
 ('Vienna',     'AT', 'east',    48.20820,  16.37380),
 ('Graz',       'AT', 'south',   47.07070,  15.43950),
 ('Prague',     'CZ', 'central', 50.07550,  14.43780),
 ('Brno',       'CZ', 'south',   49.19510,  16.60680),
 ('Zurich',     'CH', 'north',   47.37690,   8.54170),
 ('Geneva',     'CH', 'west',    46.20440,   6.14320),
 ('Stockholm',  'SE', 'east',    59.32930,  18.06860),
 ('Gothenburg', 'SE', 'west',    57.70890,  11.97460),
 ('Copenhagen', 'DK', 'east',    55.67610,  12.56830),
 ('Aarhus',     'DK', 'north',   56.16290,  10.20390),
 ('Budapest',   'HU', 'central', 47.49790,  19.04020),
 ('Debrecen',   'HU', 'east',    47.53160,  21.62730),
 ('Bucharest',  'RO', 'south',   44.42680,  26.10250),
 ('Cluj-Napoca','RO', 'north',   46.77120,  23.62360),
 ('Lisbon',     'PT', 'south',   38.72230,  -9.13930),
 ('Porto',      'PT', 'north',   41.15790,  -8.62910),
 ('Oslo',       'NO', 'north',   59.91390,  10.75220),
 ('Helsinki',   'FI', 'south',   60.16990,  24.93840),
 ('Bratislava', 'SK', 'west',    48.14860,  17.10770),
 ('Ljubljana',  'SI', 'central', 46.05690,  14.50580),
 ('Zagreb',     'HR', 'north',   45.81500,  15.98190),
 ('Vilnius',    'LT', 'east',    54.68720,  25.27970),
 ('Riga',       'LV', 'central', 56.94960,  24.10520),
 ('Tallinn',    'EE', 'north',   59.43700,  24.75360),
 ('Luxembourg', 'LU', 'central', 49.61160,   6.13190);

-- 2000 клиентов: ~15 % частных лиц (без vat_number), ~10 % без email
INSERT INTO customers (name, segment, email, vat_number, city_id, credit_limit, is_active, created_at)
SELECT CASE WHEN x.segment = 'individual'
            THEN x.first_name || ' ' || x.last_name
            ELSE x.prefix || ' ' || x.core || ' ' || x.suffix END,
       x.segment,
       CASE WHEN x.r_mail < 0.10 THEN NULL
            WHEN x.segment = 'individual'
            THEN lower(x.first_name || '.' || x.last_name) || x.g || '@' || x.mailbox
            ELSE (ARRAY['office','info','billing','logistics'])[1 + x.g % 4] || '@'
                 || lower(x.prefix || replace(x.core, ' ', '')) || '.eu' END,
       CASE WHEN x.segment = 'individual' THEN NULL
            ELSE c.country || lpad((x.g * 104729 % 1000000000)::text, 9, '0') END,
       x.city_id,
       CASE x.segment WHEN 'individual' THEN 0
                      WHEN 'smb'        THEN round((5 + x.r_lim * 45)::numeric) * 1000
                      ELSE                   round((50 + x.r_lim * 450)::numeric) * 1000 END,
       x.r_active > 0.05,
       timestamptz '2021-01-01 00:00+00' + x.r_created * interval '1095 days'
FROM (
    SELECT g,
           CASE WHEN r_seg < 0.15 THEN 'individual'
                WHEN r_seg < 0.30 THEN 'enterprise'
                ELSE 'smb' END AS segment,
           (ARRAY['Nord','Baltic','Nordic','Alpen','Rhein','Danube','Euro','Atlantic',
                  'Central','Vistula','Iberia','Adria'])[1 + floor(random() * 12)::int] AS prefix,
           (ARRAY['Steel','Logistics','Foods','Trans','Chemie','Textile','Paper','Agro',
                  'Auto Parts','Pharma','Retail','Glass'])[1 + floor(random() * 12)::int] AS core,
           (ARRAY['GmbH','AG','BV','SA','Sp. z o.o.','Ltd','s.r.o.'])[1 + floor(random() * 7)::int] AS suffix,
           (ARRAY['Anna','Jan','Maria','Piotr','Lukas','Sofia','Marco','Elena','Tomas',
                  'Julia','David','Eva'])[1 + floor(random() * 12)::int] AS first_name,
           (ARRAY['Schmidt','Kowalski','Novak','Rossi','Garcia','Jansen','Dubois',
                  'Horvath','Berg','Popescu','Silva','Weber'])[1 + floor(random() * 12)::int] AS last_name,
           (ARRAY['gmail.com','outlook.com','web.de','wp.pl','gmx.at'])[1 + floor(random() * 5)::int] AS mailbox,
           1 + floor(random() * 52)::int AS city_id,
           random() AS r_mail, random() AS r_lim, random() AS r_active, random() AS r_created
    FROM (SELECT g, random() AS r_seg FROM generate_series(1, 2000) g) s
) x
JOIN cities c ON c.id = x.city_id
ORDER BY x.g;

-- 48 диспетчеров: 1 → 2..6 → 7..18 → 19..48
INSERT INTO dispatchers (full_name, manager_id, hired_at)
SELECT (ARRAY['Anna','Jan','Maria','Piotr','Lukas','Sofia','Marco','Elena'])[1 + g % 8] || ' '
       || (ARRAY['Schmidt','Kowalski','Novak','Rossi','Garcia','Jansen'])[1 + g % 6] || ' (' || g || ')',
       CASE WHEN g = 1  THEN NULL
            WHEN g <= 6  THEN 1
            WHEN g <= 18 THEN 2 + (g - 7) % 5
            ELSE 7 + (g - 19) % 12 END,
       date '2016-01-01' + floor(random() * 2500)::int
FROM generate_series(1, 48) g
ORDER BY g;

-- 600 водителей: ~8 % уволены, водители 1–5 гарантированно работают
INSERT INTO drivers (full_name, phone, license_no, status, dispatcher_id, hired_at, terminated_at)
SELECT full_name, phone, license_no, status, dispatcher_id, hired_at,
       CASE WHEN status = 'terminated'
            THEN least(hired_at + 200 + floor(r_term * 1500)::int, date '2026-06-30') END
FROM (
    SELECT g,
           (ARRAY['Anna','Jan','Maria','Piotr','Lukas','Sofia','Marco','Elena','Tomas',
                  'Julia','David','Eva','Mateusz','Ivan','Karl'])[1 + floor(random() * 15)::int] || ' ' ||
           (ARRAY['Schmidt','Kowalski','Novak','Rossi','Garcia','Jansen','Dubois','Horvath',
                  'Berg','Popescu','Silva','Weber','Nowak','Fischer'])[1 + floor(random() * 14)::int] AS full_name,
           CASE WHEN r_phone < 0.07 THEN NULL
                WHEN r_phone < 0.40 THEN '+49 151 ' || lpad((g * 7919 % 10000)::text, 4, '0')
                                         || ' ' || lpad((g * 104 % 10000)::text, 4, '0')
                WHEN r_phone < 0.70 THEN '+48 600-' || lpad((g * 389 % 1000)::text, 3, '0')
                                         || '-' || lpad((g * 577 % 1000)::text, 3, '0')
                ELSE '(+43) 664 ' || lpad((g * 6151 % 10000000)::text, 7, '0') END AS phone,
           'DL' || lpad((g * 7907 % 1000000)::text, 6, '0') AS license_no,
           CASE WHEN g <= 5         THEN 'active'
                WHEN r_status < 0.08 THEN 'terminated'
                WHEN r_status < 0.13 THEN 'on_leave'
                ELSE 'active' END AS status,
           19 + (g - 1) % 30 AS dispatcher_id,
           date '2015-01-01' + floor(random() * 3800)::int AS hired_at,
           random() AS r_term
    FROM (SELECT g, random() AS r_phone, random() AS r_status FROM generate_series(1, 600) g) s
) x
ORDER BY g;

-- 450 грузовиков, capacity_kg определяется моделью
INSERT INTO trucks (plate, model, year_built, capacity_kg)
SELECT (ARRAY['B','HH','M','K','F','S'])[1 + g % 6] || '-'
       || chr(65 + g % 26) || chr(65 + (g / 26) % 26) || ' ' || lpad(g::text, 4, '0'),
       m.model, (2010 + floor(random() * 16))::smallint, m.capacity_kg
FROM (SELECT g, 1 + floor(random() * 8)::int AS mi FROM generate_series(1, 450) g) s
JOIN (VALUES (1, 'MAN TGX', 24000), (2, 'Volvo FH', 25000), (3, 'Scania R', 24000),
             (4, 'DAF XF', 24000), (5, 'Mercedes Actros', 25000), (6, 'Renault T', 24000),
             (7, 'DAF LF', 12000), (8, 'Iveco Daily', 3500)) AS m (mi, model, capacity_kg)
  ON m.mi = s.mi
ORDER BY g;

-- ---------------------------------------------------------------------
-- Данные: перевозки
-- ---------------------------------------------------------------------

-- 300 000 перевозок за 2024-01-01 .. 2026-07-01, вставлены в случайном
-- порядке по дате. ~82 % delivered, у created нет диспетчера.
-- Клиенты 1–380 дают ~60 % перевозок, клиенты 1901–2000 — ни одной.
INSERT INTO shipments (public_id, customer_id, status, dispatcher_id, priority,
                       origin_city_id, origin_country, dest_city_id, weight_kg, declared_value,
                       created_at, picked_up_at, delivered_at, tags, meta)
SELECT md5('shipment:' || x.g)::uuid,
       x.customer_id,
       x.status,
       CASE WHEN x.status = 'created' THEN NULL ELSE x.dispatcher_id END,
       x.priority,
       x.o, oc.country, x.d,
       x.weight_kg,
       round((x.weight_kg * (2 + x.r_val * 30))::numeric, 2),
       x.created_at,
       CASE WHEN x.status IN ('in_transit', 'delivered')
            THEN x.created_at + x.pick_h * interval '1 hour' END,
       CASE WHEN x.status = 'delivered'
            THEN x.created_at + x.pick_h * interval '1 hour'
                 + (dd.km / 65.0 * (1.1 + x.r_tr * 0.6) + 4 + x.r_tr2 * 20) * interval '1 hour' END,
       x.tags,
       x.meta || CASE WHEN oc.country IN ('CH', 'NO') OR dc.country IN ('CH', 'NO')
                      THEN '{"customs": true}'::jsonb ELSE '{}'::jsonb END
FROM (
    SELECT y.*,
           1 + ((y.o - 1) + 1 + floor(y.r_d * 51)::int) % 52 AS d,
           CASE WHEN y.created_at > timestamptz '2026-06-20 00:00+00' THEN
                     (ARRAY['created','created','assigned','in_transit'])[1 + floor(y.r_st * 4)::int]
                WHEN y.r_st < 0.829 THEN 'delivered'
                WHEN y.r_st < 0.879 THEN 'cancelled'
                WHEN y.r_st < 0.905 THEN 'created'
                WHEN y.r_st < 0.945 THEN 'assigned'
                ELSE 'in_transit' END AS status,
           CASE WHEN y.r_w < 0.34 THEN 50 + floor(random() * 950)::int
                WHEN y.r_w < 0.75 THEN 1000 + floor(random() * 9000)::int
                ELSE 10000 + floor(random() * 14000)::int END AS weight_kg,
           CASE WHEN y.r_tag < 0.70 THEN '{}'::text[]
                ELSE CASE floor(random() * 7)::int
                         WHEN 0 THEN ARRAY['fragile']
                         WHEN 1 THEN ARRAY['hazmat']
                         WHEN 2 THEN ARRAY['oversize']
                         WHEN 3 THEN ARRAY['urgent']
                         WHEN 4 THEN ARRAY['temperature_controlled']
                         WHEN 5 THEN ARRAY['hazmat', 'fragile']
                         ELSE        ARRAY['fragile', 'urgent'] END
           END AS tags,
           CASE WHEN y.r_meta < 0.08 THEN '{}'::jsonb
                ELSE jsonb_build_object(
                       'incoterm', (ARRAY['EXW','FCA','CPT','DAP','DDP'])[1 + floor(random() * 5)::int],
                       'pallets',  1 + floor(random() * 33)::int) END AS meta
    FROM (
        SELECT g,
               CASE WHEN random() < 0.6 THEN 1 + floor(random() * 380)::int
                    ELSE 1 + floor(random() * 1900)::int END AS customer_id,
               1 + floor(random() * 52)::int AS o,
               random() AS r_d,
               timestamptz '2024-01-01 00:00+00'
                 + random() * (timestamptz '2026-07-01 00:00+00' - timestamptz '2024-01-01 00:00+00') AS created_at,
               random() AS r_st,
               19 + floor(random() * 30)::int AS dispatcher_id,
               CASE WHEN r_p < 0.75 THEN 'standard'
                    WHEN r_p < 0.95 THEN 'express'
                    ELSE 'critical' END AS priority,
               random() AS r_w, random() AS r_val, random() AS r_tag, random() AS r_meta,
               24 + random() * 48 AS pick_h,
               random() AS r_tr, random() AS r_tr2
        FROM (SELECT g, random() AS r_p FROM generate_series(1, 300000) g) z
    ) y
) x
JOIN cities oc ON oc.id = x.o
JOIN cities dc ON dc.id = x.d
CROSS JOIN LATERAL (
    SELECT sqrt(power((dc.lat - oc.lat) * 111, 2)
              + power((dc.lon - oc.lon) * 111 * cos(radians((oc.lat + dc.lat) / 2)), 2)) AS km
) dd
ORDER BY x.g;

-- Назначения: у assigned / in_transit / delivered и у трети cancelled.
-- У ~15 % перевозок два назначения, первое снято с причиной reassigned.
-- Водители 571–600 и грузовики 431–450 не назначаются никогда.
INSERT INTO assignments (shipment_id, driver_id, truck_id, assigned_at, released_at, release_reason)
SELECT s.id,
       1 + floor(random() * 570)::int,
       1 + floor(random() * 430)::int,
       s.first_at + (n.n - 1) * s.gap_h * interval '1 hour',
       CASE WHEN n.n < n.total THEN s.first_at + s.gap_h * interval '1 hour'
            WHEN s.status = 'cancelled' THEN s.first_at + (n.n - 1) * s.gap_h * interval '1 hour'
                                             + interval '6 hours' END,
       CASE WHEN n.n < n.total THEN 'reassigned'
            WHEN s.status = 'cancelled' THEN 'cancelled' END
FROM (
    SELECT id, status,
           created_at + (0.5 + random() * 18) * interval '1 hour' AS first_at,
           1 + random() * 4 AS gap_h,
           random() < 0.15 AS two
    FROM shipments
    WHERE status IN ('assigned', 'in_transit', 'delivered')
       OR (status = 'cancelled' AND id % 3 = 0)
) s
CROSS JOIN LATERAL (
    SELECT n, CASE WHEN s.two THEN 2 ELSE 1 END AS total
    FROM generate_series(1, CASE WHEN s.two THEN 2 ELSE 1 END) n
) n
ORDER BY s.id, n.n;

-- ---------------------------------------------------------------------
-- Данные: трекинг
-- ---------------------------------------------------------------------

-- ~2.5 млн событий, физически вставлены в порядке времени (важно для BRIN).
-- Точки лежат на прямой между городами с шумом. 0.2 % событий продублированы.
WITH ev AS (
    SELECT s.id AS shipment_id,
           k.k,
           s.picked_up_at + CASE WHEN s.status = 'delivered'
                                 THEN (s.delivered_at - s.picked_up_at) * (k.k / 9.0)
                                 ELSE k.k * interval '4 hours' END AS occurred_at,
           CASE WHEN k.k = 0 THEN 'pickup'
                WHEN s.status = 'delivered' AND k.k = 9 THEN 'delivery'
                WHEN r.r < 0.06 THEN 'checkpoint'
                WHEN r.r < 0.16 THEN 'stop'
                ELSE 'gps' END AS event_type,
           r.r_speed,
           CASE WHEN s.status = 'delivered' THEN k.k / 9.0 ELSE k.k / 12.0 END AS frac,
           oc.lat AS lat0, oc.lon AS lon0, dc.lat AS lat1, dc.lon AS lon1,
           r.r_lat, r.r_lon
    FROM shipments s
    JOIN cities oc ON oc.id = s.origin_city_id
    JOIN cities dc ON dc.id = s.dest_city_id
    CROSS JOIN LATERAL generate_series(0, CASE WHEN s.status = 'delivered' THEN 9
                                               ELSE 2 + (s.id % 4)::int END) AS k (k)
    CROSS JOIN LATERAL (SELECT random() AS r, random() AS r_speed,
                               random() AS r_lat, random() AS r_lon
                        WHERE k.k >= 0) r
    WHERE s.picked_up_at IS NOT NULL
),
ev_rows AS (
    SELECT shipment_id, occurred_at, event_type,
           CASE event_type WHEN 'gps' THEN 40 + floor(r_speed * 55)::int
                           WHEN 'checkpoint' THEN 0 END AS speed_kmh,
           round((lat0 + (lat1 - lat0) * frac + (r_lat - 0.5) * 0.1)::numeric, 5) AS lat,
           round((lon0 + (lon1 - lon0) * frac + (r_lon - 0.5) * 0.1)::numeric, 5) AS lon,
           (shipment_id * 7 + k) % 500 = 0 AS dup
    FROM ev
)
INSERT INTO tracking_events (shipment_id, occurred_at, event_type, speed_kmh, lat, lon)
SELECT shipment_id, occurred_at, event_type, speed_kmh, lat, lon
FROM (
    SELECT * FROM ev_rows
    UNION ALL
    SELECT * FROM ev_rows WHERE dup
) t
ORDER BY occurred_at, shipment_id;

-- ---------------------------------------------------------------------
-- Данные: деньги
-- ---------------------------------------------------------------------

-- Один счёт на доставленную перевозку. EUR ~92 %, PLN, CHF.
-- Дата счёта — день доставки по UTC, явно, чтобы не зависеть от TimeZone.
INSERT INTO invoices (shipment_id, amount, currency, issued_at, due_at)
SELECT id,
       round((base * CASE cur WHEN 'PLN' THEN 4.30 WHEN 'CHF' THEN 0.95 ELSE 1 END)::numeric, 2),
       cur,
       (delivered_at AT TIME ZONE 'UTC')::date,
       (delivered_at AT TIME ZONE 'UTC')::date + terms
FROM (
    SELECT id, delivered_at,
           150 + weight_kg * (0.05 + random() * 0.08) AS base,
           CASE WHEN r_cur < 0.92 THEN 'EUR' WHEN r_cur < 0.97 THEN 'PLN' ELSE 'CHF' END AS cur,
           (ARRAY[14, 30, 30, 45, 60])[1 + floor(random() * 5)::int] AS terms
    FROM (SELECT id, delivered_at, weight_kg, random() AS r_cur
          FROM shipments WHERE status = 'delivered') s
) x
ORDER BY delivered_at, id;

-- Оплаты: ~70 % счетов оплачены одним платежом, ~6 % двумя частями,
-- ~6 % оплачены частично, остальные открыты.
INSERT INTO payments (invoice_id, amount, paid_at)
SELECT i.id,
       CASE WHEN i.kind = 'partial' THEN round(i.amount * i.share, 2)
            WHEN i.kind = 'split' AND n.n = 1 THEN round(i.amount * i.share, 2)
            WHEN i.kind = 'split' THEN i.amount - round(i.amount * i.share, 2)
            ELSE i.amount END,
       (i.issued_at::timestamp AT TIME ZONE 'UTC')
         + (1 + i.r_day * (i.due_at - i.issued_at + 15)) * interval '1 day'
         + (n.n - 1) * (5 + i.r_gap * 20) * interval '1 day'
FROM (
    SELECT id, amount, issued_at, due_at,
           CASE WHEN r < 0.18 THEN 'open'
                WHEN r < 0.24 THEN 'partial'
                WHEN r < 0.30 THEN 'split'
                ELSE 'full' END AS kind,
           (0.3 + random() * 0.5)::numeric AS share,
           random() AS r_day, random() AS r_gap
    FROM (SELECT id, amount, issued_at, due_at, random() AS r FROM invoices) s
) i
CROSS JOIN LATERAL generate_series(1, CASE WHEN i.kind = 'split' THEN 2 ELSE 1 END) AS n (n)
WHERE i.kind <> 'open'
ORDER BY 3, 1;

-- ---------------------------------------------------------------------
-- Данные: очередь задач
-- ---------------------------------------------------------------------

INSERT INTO job_queue (kind, payload, status, attempts, run_after, created_at)
SELECT (ARRAY['send_invoice', 'recalc_rating', 'notify_driver', 'sync_gps'])[1 + g % 4],
       jsonb_build_object('shipment_id', 1 + (g * 37 % 300000)),
       CASE WHEN g % 10 < 7 THEN 'done' WHEN g % 10 < 9 THEN 'pending' ELSE 'failed' END,
       g % 4,
       timestamptz '2026-06-01 00:00+00' + g * interval '2 minutes',
       timestamptz '2026-06-01 00:00+00' + g * interval '2 minutes' - interval '5 minutes'
FROM generate_series(1, 20000) g;

-- Статистика для планировщика
ANALYZE;

-- ---------------------------------------------------------------------
-- Контроль. Порядок строк в первой табличке не гарантирован: UNION ALL
-- без ORDER BY (урок 1.1).
-- ---------------------------------------------------------------------
SELECT 'cities' AS table_name, count(*) AS row_count FROM cities
UNION ALL SELECT 'customers',       count(*) FROM customers
UNION ALL SELECT 'dispatchers',     count(*) FROM dispatchers
UNION ALL SELECT 'drivers',         count(*) FROM drivers
UNION ALL SELECT 'trucks',          count(*) FROM trucks
UNION ALL SELECT 'shipments',       count(*) FROM shipments
UNION ALL SELECT 'assignments',     count(*) FROM assignments
UNION ALL SELECT 'tracking_events', count(*) FROM tracking_events
UNION ALL SELECT 'invoices',        count(*) FROM invoices
UNION ALL SELECT 'payments',        count(*) FROM payments
UNION ALL SELECT 'job_queue',       count(*) FROM job_queue;

SELECT 'delivered, %' AS check_name,
       round(100.0 * count(*) FILTER (WHERE status = 'delivered') / count(*), 1)::text AS value
FROM shipments
UNION ALL
SELECT 'created без диспетчера',
       count(*) FILTER (WHERE status = 'created' AND dispatcher_id IS NULL)::text
FROM shipments
UNION ALL
SELECT 'клиенты без перевозок',
       count(*)::text
FROM customers c WHERE NOT EXISTS (SELECT 1 FROM shipments s WHERE s.customer_id = c.id)
UNION ALL
SELECT 'перевозки с двумя назначениями, %',
       round(100.0 * count(*) FILTER (WHERE cnt = 2) / count(*), 1)::text
FROM (SELECT shipment_id, count(*) AS cnt FROM assignments GROUP BY shipment_id) a
UNION ALL
SELECT 'счета в EUR, %',
       round(100.0 * count(*) FILTER (WHERE currency = 'EUR') / count(*), 1)::text
FROM invoices;
