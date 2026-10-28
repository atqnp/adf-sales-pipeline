-- Every table the course uses: control table (Module 2), fact table for the
-- Data Flow upsert (Module 3A), watermark (Module 3B). Safe to rerun.
-- scripts/deploy_module2.sh runs it with sqlcmd; or paste it into
-- Portal > SQL database > Query editor.

IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
IF SCHEMA_ID('src') IS NULL EXEC('CREATE SCHEMA src');
GO

-- Module 2: metadata-driven ingestion, read by the Lookup activity
IF OBJECT_ID('etl.config') IS NULL
CREATE TABLE etl.config (
  table_name   varchar(100) PRIMARY KEY,
  source_file  varchar(200) NOT NULL,
  is_active    bit          NOT NULL DEFAULT 1,
  load_type    varchar(20)  NOT NULL DEFAULT 'full'   -- 'full' or 'incremental'
);
GO
MERGE etl.config AS t
USING (VALUES
  ('orders',    'orders.csv',    'incremental'),
  ('customers', 'customers.csv', 'full'),
  ('products',  'products.csv',  'full'),
  ('dates',     'dates.csv',     'full')
) AS s (table_name, source_file, load_type)
ON t.table_name = s.table_name
WHEN NOT MATCHED THEN INSERT (table_name, source_file, is_active, load_type)
  VALUES (s.table_name, s.source_file, 1, s.load_type);
GO

-- Module 2: run log written by a Stored procedure activity after each Copy
IF OBJECT_ID('etl.run_log') IS NULL
CREATE TABLE etl.run_log (
  log_id       int IDENTITY PRIMARY KEY,
  run_id       varchar(100),
  table_name   varchar(100),
  rows_copied  bigint,
  status       varchar(20),
  logged_at    datetime2 DEFAULT sysutcdatetime()
);
GO
CREATE OR ALTER PROCEDURE etl.usp_log_run
  @run_id varchar(100), @table_name varchar(100), @rows_copied bigint, @status varchar(20)
AS
  INSERT INTO etl.run_log (run_id, table_name, rows_copied, status)
  VALUES (@run_id, @table_name, @rows_copied, @status);
GO

-- Module 3A: target of the Mapping Data Flow upsert
IF OBJECT_ID('dbo.fact_sales') IS NULL
CREATE TABLE dbo.fact_sales (
  order_id     varchar(50) PRIMARY KEY,
  order_date   date,
  customer_id  varchar(50),
  product_id   varchar(50),
  quantity     int,
  amount       decimal(18,2),
  loaded_at    datetime2
);
GO

-- Module 3B: watermark pattern
IF OBJECT_ID('etl.watermark') IS NULL
CREATE TABLE etl.watermark (table_name varchar(100) PRIMARY KEY, last_modified datetime2);
GO
IF NOT EXISTS (SELECT 1 FROM etl.watermark WHERE table_name = 'orders')
  INSERT INTO etl.watermark VALUES ('orders', '1900-01-01');
GO
CREATE OR ALTER PROCEDURE etl.usp_update_watermark @table_name varchar(100), @wm datetime2
AS UPDATE etl.watermark SET last_modified = @wm WHERE table_name = @table_name;
GO

-- Module 3B needs a database source with modified_at. Load orders.csv into
-- src.orders once (e.g. a Copy activity from raw/landing/orders.csv), then the
-- watermark Copy reads from here.
IF OBJECT_ID('src.orders') IS NULL
CREATE TABLE src.orders (
  order_id     varchar(50),
  order_date   date,
  customer_id  varchar(50),
  product_id   varchar(50),
  quantity     int,
  unit_price   decimal(18,2),
  modified_at  datetime2
);
GO
