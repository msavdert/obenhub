-- Stage 2: the `app` database schema, identical on publisher and subscriber
-- (logical replication does not copy DDL).
CREATE TABLE customers (
  id   bigint PRIMARY KEY,
  name text NOT NULL
);
CREATE TABLE orders (
  id          bigint PRIMARY KEY,
  customer_id bigint NOT NULL,
  amount      numeric(12, 2) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
