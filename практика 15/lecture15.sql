-- Стартовое состояние
SELECT * FROM l15_v_reconciliation;
SELECT order_id, status, amount, channel, version FROM l15_orders WHERE order_id IN (1530005, 1530011, 1530012);

-- Опыт 1: три изменения
UPDATE l15_orders SET status = 'paid' WHERE order_id = 1530005;
UPDATE l15_orders SET amount = 999.00 WHERE order_id = 1530011;
UPDATE l15_orders SET channel = 'partner' WHERE order_id = 1530012;
UPDATE l15_orders SET amount = 999.00 WHERE order_id = 1530011;
SELECT COUNT(*) FROM l15_outbox_events;
SELECT event_key, version FROM l15_outbox_events WHERE order_id IN (1530005, 1530011, 1530012) ORDER BY event_id;
SELECT * FROM l15_v_reconciliation;

-- Опыт 2: две микропартии
SELECT l15_apply_batch(2) AS first_microbatch;
SELECT * FROM l15_v_reconciliation;
SELECT l15_apply_batch(100) AS remaining_batch;
SELECT * FROM l15_v_reconciliation;
SELECT l15_apply_batch(100) AS should_be_zero;

-- Опыт 3: поздний январский заказ
INSERT INTO l15_orders (order_id, customer_id, order_date, channel, status, amount)
VALUES (1539901, 1510001, DATE '2025-01-15', 'app', 'paid', 450.00)
ON CONFLICT (order_id) DO NOTHING;
INSERT INTO l15_orders (order_id, customer_id, order_date, channel, status, amount)
VALUES (1539901, 1510001, DATE '2025-01-15', 'app', 'paid', 450.00)
ON CONFLICT (order_id) DO NOTHING;
SELECT revenue FROM l15_daily_metrics WHERE order_date = '2025-01-15' AND channel = 'app';
SELECT l15_apply_batch(100);
SELECT revenue FROM l15_daily_metrics WHERE order_date = '2025-01-15' AND channel = 'app';
SELECT created_at::date AS created, payload->>'order_date' AS order_date FROM l15_outbox_events WHERE order_id = 1539901;
SELECT * FROM l15_v_reconciliation;

-- Опыт 4: некорректный payload
INSERT INTO l15_outbox_events (event_key, order_id, version, event_kind, payload)
VALUES ('demo:bad:1539998:v1', 1539998, 1, 'order_created',
 '{"order_id":1539998,"customer_id":1510001,"order_date":"2025-01-20","channel":"web","status":"paid","amount":"not-a-number"}');
SELECT l15_apply_batch(100);
SELECT event_key, reason FROM l15_dead_letters;
SELECT event_key, outcome FROM l15_processed_events WHERE outcome = 'dead_letter';
SELECT * FROM l15_v_reconciliation;

-- Опыт 5: старая версия
INSERT INTO l15_outbox_events (event_key, order_id, version, event_kind, payload)
VALUES ('demo:stale:1530011:v1', 1530011, 1, 'order_updated',
 (SELECT to_jsonb(o) - 'version' || '{"amount": 1.00}'::jsonb FROM l15_orders o WHERE order_id = 1530011));
SELECT l15_apply_batch(100);
SELECT order_id, amount, last_version FROM l15_order_projection WHERE order_id = 1530011;
SELECT event_key, outcome FROM l15_processed_events WHERE outcome = 'stale';
SELECT * FROM l15_v_reconciliation;

-- Сверка по датам и каналам (пусто = различий нет)
SELECT COALESCE(p.order_date, m.order_date) AS order_date, COALESCE(p.channel, m.channel) AS channel,
       p.revenue AS projection_revenue, m.revenue AS mart_revenue
FROM (SELECT order_date, channel, COUNT(*) AS cnt, SUM(amount) AS revenue
      FROM l15_order_projection WHERE status = 'paid' GROUP BY 1, 2) p
FULL JOIN l15_daily_metrics m ON m.order_date = p.order_date AND m.channel = p.channel
WHERE p.revenue IS DISTINCT FROM m.revenue AND NOT (m.paid_orders = 0 AND p.revenue IS NULL);

-- Итог по исходам
SELECT outcome, COUNT(*) FROM l15_processed_events GROUP BY outcome ORDER BY 1;
