-- =====================================================================
-- RavenStack - 00_setup_star_schema.sql
-- Complete setup script. Safe to run from start to finish on an empty database.
-- =====================================================================
-- Prerequisites before running:
--   1. The 5 CSV files (accounts, subscriptions, feature_usage,
--      support_tickets, churn_events) must first be loaded into SQL Server
--      as raw tables, either through the SSMS Import Flat File Wizard
--      or through the commented BULK INSERT section below (update the paths).
--   2. If the Import Wizard was used, the tables may be named after
--      the source files (ravenstack_accounts...). This script automatically
--      renames them when those names are detected.
--
-- This script is idempotent: it can be safely re-run on the same database.
-- It drops and rebuilds the Star Schema tables each time.
-- =====================================================================


-- =====================================================================
-- 0. Create the database if it does not already exist
-- =====================================================================
IF DB_ID('RavenStack') IS NULL
BEGIN
    CREATE DATABASE RavenStack;
END
GO

USE RavenStack;
GO


-- =====================================================================
-- 0.1 [Optional] Import CSV files directly using BULK INSERT instead of the Wizard
--     Update the file paths and uncomment this section if you prefer this method.
--     Note: BULK INSERT requires SQL Server itself to have access to the path
--     (for a local server, a path on your machine can be used).
-- =====================================================================
/*
IF OBJECT_ID('accounts','U') IS NULL
BEGIN
    CREATE TABLE accounts (
        account_id NVARCHAR(50), account_name NVARCHAR(200), industry NVARCHAR(100),
        country NVARCHAR(10), signup_date DATE, referral_source NVARCHAR(50),
        plan_tier NVARCHAR(50), seats INT, is_trial BIT, churn_flag BIT
    );
    BULK INSERT accounts FROM 'D:\data analysis data\RavenStack\ravenstack_accounts.csv'
    WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');
END
-- Repeat the same approach for the remaining 4 tables (subscriptions, feature_usage,
-- support_tickets, churn_events), using the columns defined in the dataset documentation.
*/
GO


-- =====================================================================
-- 1. Rename raw tables if they still use the ravenstack_* names from the Import Wizard
-- =====================================================================
IF OBJECT_ID('dbo.ravenstack_accounts','U') IS NOT NULL AND OBJECT_ID('dbo.accounts','U') IS NULL
    EXEC sp_rename 'dbo.ravenstack_accounts', 'accounts';
IF OBJECT_ID('dbo.ravenstack_subscriptions','U') IS NOT NULL AND OBJECT_ID('dbo.subscriptions','U') IS NULL
    EXEC sp_rename 'dbo.ravenstack_subscriptions', 'subscriptions';
IF OBJECT_ID('dbo.ravenstack_feature_usage','U') IS NOT NULL AND OBJECT_ID('dbo.feature_usage','U') IS NULL
    EXEC sp_rename 'dbo.ravenstack_feature_usage', 'feature_usage';
IF OBJECT_ID('dbo.ravenstack_support_tickets','U') IS NOT NULL AND OBJECT_ID('dbo.support_tickets','U') IS NULL
    EXEC sp_rename 'dbo.ravenstack_support_tickets', 'support_tickets';
IF OBJECT_ID('dbo.ravenstack_churn_events','U') IS NOT NULL AND OBJECT_ID('dbo.churn_events','U') IS NULL
    EXEC sp_rename 'dbo.ravenstack_churn_events', 'churn_events';
GO

-- Verify that the required raw tables exist before continuing
IF OBJECT_ID('dbo.accounts','U') IS NULL
BEGIN
    RAISERROR('جدول accounts مش موجود. لازم تستوردي الـ CSVs الأول (شوفي التعليمات فوق).', 16, 1);
    RETURN;
END
GO


-- =====================================================================
-- 2. Drop any existing Star Schema tables for safe repeated execution
-- =====================================================================
IF OBJECT_ID('fact_account_summary','U') IS NOT NULL DROP TABLE fact_account_summary;
IF OBJECT_ID('fact_churn_events','U')    IS NOT NULL DROP TABLE fact_churn_events;
IF OBJECT_ID('fact_support_tickets','U') IS NOT NULL DROP TABLE fact_support_tickets;
IF OBJECT_ID('fact_feature_usage','U')   IS NOT NULL DROP TABLE fact_feature_usage;
IF OBJECT_ID('fact_subscriptions','U')   IS NOT NULL DROP TABLE fact_subscriptions;
IF OBJECT_ID('dim_account','U')          IS NOT NULL DROP TABLE dim_account;
IF OBJECT_ID('dim_date','U')             IS NOT NULL DROP TABLE dim_date;
IF OBJECT_ID('dim_industry','U')         IS NOT NULL DROP TABLE dim_industry;
IF OBJECT_ID('dim_plan_tier','U')        IS NOT NULL DROP TABLE dim_plan_tier;
IF OBJECT_ID('dim_referral_source','U')  IS NOT NULL DROP TABLE dim_referral_source;
IF OBJECT_ID('dim_reason_code','U')      IS NOT NULL DROP TABLE dim_reason_code;
GO


-- =====================================================================
-- 3. Dimension tables (lookup tables)
-- =====================================================================
CREATE TABLE dim_industry (
    industry_id     INT IDENTITY(1,1) PRIMARY KEY,
    industry_name   NVARCHAR(100) NOT NULL UNIQUE
);
INSERT INTO dim_industry (industry_name)
SELECT DISTINCT industry FROM accounts WHERE industry IS NOT NULL;

CREATE TABLE dim_plan_tier (
    plan_tier_id    INT IDENTITY(1,1) PRIMARY KEY,
    plan_tier_name  NVARCHAR(50) NOT NULL UNIQUE
);
INSERT INTO dim_plan_tier (plan_tier_name)
SELECT DISTINCT plan_tier FROM (
    SELECT plan_tier FROM accounts WHERE plan_tier IS NOT NULL
    UNION
    SELECT plan_tier FROM subscriptions WHERE plan_tier IS NOT NULL
) t;

CREATE TABLE dim_referral_source (
    referral_source_id     INT IDENTITY(1,1) PRIMARY KEY,
    referral_source_name   NVARCHAR(50) NOT NULL UNIQUE
);
INSERT INTO dim_referral_source (referral_source_name)
SELECT DISTINCT referral_source FROM accounts WHERE referral_source IS NOT NULL;

CREATE TABLE dim_reason_code (
    reason_code_id      INT IDENTITY(1,1) PRIMARY KEY,
    reason_code_name    NVARCHAR(50) NOT NULL UNIQUE
);
INSERT INTO dim_reason_code (reason_code_name)
SELECT DISTINCT reason_code FROM churn_events WHERE reason_code IS NOT NULL;
GO


-- =====================================================================
-- 4. dim_account
-- =====================================================================
SELECT
    acc.account_id,
    acc.account_name,
    di.industry_id,
    acc.country,
    drs.referral_source_id,
    dpt.plan_tier_id           AS initial_plan_tier_id,
    acc.seats                  AS initial_seats,
    acc.signup_date,
    acc.is_trial,
    acc.churn_flag
INTO dim_account
FROM accounts acc
LEFT JOIN dim_industry di          ON acc.industry = di.industry_name
LEFT JOIN dim_referral_source drs  ON acc.referral_source = drs.referral_source_name
LEFT JOIN dim_plan_tier dpt        ON acc.plan_tier = dpt.plan_tier_name;
GO

ALTER TABLE dim_account ALTER COLUMN account_id NVARCHAR(50) NOT NULL;
ALTER TABLE dim_account ADD CONSTRAINT PK_dim_account PRIMARY KEY (account_id);
GO


-- =====================================================================
-- 5. dim_date -- generated using a Tally Table approach without recursion
-- =====================================================================
DECLARE @start_date DATE, @end_date DATE;

SELECT @start_date = MIN(d) FROM (
    SELECT MIN(signup_date) AS d FROM accounts
    UNION ALL SELECT MIN(start_date) FROM subscriptions
    UNION ALL SELECT MIN(CAST(submitted_at AS DATE)) FROM support_tickets
    UNION ALL SELECT MIN(churn_date) FROM churn_events
) t;

SELECT @end_date = MAX(d) FROM (
    SELECT MAX(signup_date) AS d FROM accounts
    UNION ALL SELECT MAX(COALESCE(end_date, start_date)) FROM subscriptions
    UNION ALL SELECT MAX(CAST(closed_at AS DATE)) FROM support_tickets
    UNION ALL SELECT MAX(churn_date) FROM churn_events
) t;

;WITH E1(N) AS (
    SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1
    UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1 UNION ALL SELECT 1
),
E2(N) AS (SELECT 1 FROM E1 a CROSS JOIN E1 b),
E4(N) AS (SELECT 1 FROM E2 a CROSS JOIN E2 b),
cteTally AS (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn FROM E4)
SELECT
    date_key,
    YEAR(date_key)                      AS [year],
    MONTH(date_key)                     AS [month],
    DAY(date_key)                       AS [day],
    FORMAT(date_key, 'yyyy-MM')          AS year_month,
    DATENAME(MONTH, date_key)            AS month_name,
    DATEPART(WEEKDAY, date_key)          AS weekday_num
INTO dim_date
FROM (
    SELECT DATEADD(DAY, rn - 1, @start_date) AS date_key
    FROM cteTally
    WHERE rn <= DATEDIFF(DAY, @start_date, @end_date) + 1
) d;
GO

ALTER TABLE dim_date ALTER COLUMN date_key DATE NOT NULL;
ALTER TABLE dim_date ADD CONSTRAINT PK_dim_date PRIMARY KEY (date_key);
GO


-- =====================================================================
-- 6. fact_subscriptions
-- =====================================================================
SELECT
    sub.subscription_id,
    sub.account_id,
    dpt.plan_tier_id,
    sub.start_date,
    sub.end_date,
    sub.seats,
    sub.mrr_amount,
    sub.arr_amount,
    sub.is_trial,
    sub.upgrade_flag,
    sub.downgrade_flag,
    sub.churn_flag,
    sub.billing_frequency,
    sub.auto_renew_flag,
    CASE
        WHEN sub.end_date IS NOT NULL
        THEN DATEDIFF(DAY, sub.start_date, sub.end_date)
        ELSE NULL
    END AS subscription_duration_days
INTO fact_subscriptions
FROM subscriptions sub
LEFT JOIN dim_plan_tier dpt ON sub.plan_tier = dpt.plan_tier_name;
GO

ALTER TABLE fact_subscriptions ALTER COLUMN subscription_id NVARCHAR(50) NOT NULL;
ALTER TABLE fact_subscriptions ADD CONSTRAINT PK_fact_subscriptions PRIMARY KEY (subscription_id);
GO


-- =====================================================================
-- 7. fact_feature_usage -- remove duplicate usage_id values before
--    adding the Primary Key
-- =====================================================================
SELECT
    fu.usage_id,
    fu.subscription_id,
    sub.account_id,
    fu.usage_date,
    fu.feature_name,
    fu.usage_count,
    fu.usage_duration_secs,
    fu.error_count,
    fu.is_beta_feature,
    ROW_NUMBER() OVER (PARTITION BY fu.usage_id ORDER BY (SELECT NULL)) AS rn_dedupe
INTO #fact_feature_usage_staging
FROM feature_usage fu
INNER JOIN subscriptions sub ON fu.subscription_id = sub.subscription_id;

SELECT
    usage_id, subscription_id, account_id, usage_date, feature_name,
    usage_count, usage_duration_secs, error_count, is_beta_feature
INTO fact_feature_usage
FROM #fact_feature_usage_staging
WHERE rn_dedupe = 1;

DROP TABLE #fact_feature_usage_staging;
GO

ALTER TABLE fact_feature_usage ALTER COLUMN usage_id NVARCHAR(50) NOT NULL;
ALTER TABLE fact_feature_usage ADD CONSTRAINT PK_fact_feature_usage PRIMARY KEY (usage_id);
GO


-- =====================================================================
-- 8. fact_support_tickets
-- =====================================================================
SELECT
    ticket_id,
    account_id,
    CAST(submitted_at AS DATE) AS ticket_date,
    submitted_at,
    closed_at,
    resolution_time_hours,
    priority,
    first_response_time_minutes,
    satisfaction_score,
    escalation_flag
INTO fact_support_tickets
FROM support_tickets;
GO

ALTER TABLE fact_support_tickets ALTER COLUMN ticket_id NVARCHAR(50) NOT NULL;
ALTER TABLE fact_support_tickets ADD CONSTRAINT PK_fact_support_tickets PRIMARY KEY (ticket_id);
GO


-- =====================================================================
-- 9. fact_churn_events
-- =====================================================================
SELECT
    ce.churn_event_id,
    ce.account_id,
    drc.reason_code_id,
    ce.churn_date,
    ce.refund_amount_usd,
    ce.preceding_upgrade_flag,
    ce.preceding_downgrade_flag,
    ce.is_reactivation,
    ce.feedback_text
INTO fact_churn_events
FROM churn_events ce
LEFT JOIN dim_reason_code drc ON ce.reason_code = drc.reason_code_name;
GO

ALTER TABLE fact_churn_events ALTER COLUMN churn_event_id NVARCHAR(50) NOT NULL;
ALTER TABLE fact_churn_events ADD CONSTRAINT PK_fact_churn_events PRIMARY KEY (churn_event_id);
GO


-- =====================================================================
-- 10. fact_account_summary -- business_risk_tier is based on the actual
--     data distribution rather than predefined placeholder thresholds
-- =====================================================================
WITH sub_agg AS (
    SELECT
        account_id,
        SUM(mrr_amount)                                     AS total_mrr,
        SUM(arr_amount)                                     AS total_arr,
        MAX(seats)                                           AS max_seats,
        MAX(CASE WHEN upgrade_flag = 1 THEN 1 ELSE 0 END)    AS had_upgrade,
        MAX(CASE WHEN downgrade_flag = 1 THEN 1 ELSE 0 END)  AS had_downgrade,
        COUNT(subscription_id)                                AS subscription_count
    FROM subscriptions
    GROUP BY account_id
),
ticket_agg AS (
    SELECT
        account_id,
        COUNT(ticket_id)                                      AS total_tickets,
        AVG(resolution_time_hours)                             AS avg_resolution_hours,
        AVG(CAST(satisfaction_score AS FLOAT))                 AS avg_satisfaction,
        SUM(CASE WHEN escalation_flag = 1 THEN 1 ELSE 0 END)   AS total_escalations
    FROM support_tickets
    GROUP BY account_id
),
usage_agg AS (
    SELECT
        sub.account_id,
        SUM(fu.usage_count)                                    AS total_usage_events,
        SUM(fu.usage_duration_secs)                            AS total_duration_secs,
        SUM(fu.error_count)                                    AS total_errors,
        COUNT(DISTINCT fu.feature_name)                        AS distinct_features_used,
        SUM(CASE WHEN fu.is_beta_feature = 1 THEN 1 ELSE 0 END) AS beta_features_used
    FROM feature_usage fu
    INNER JOIN subscriptions sub ON fu.subscription_id = sub.subscription_id
    GROUP BY sub.account_id
),
churn_agg AS (
    SELECT
        account_id,
        MIN(churn_date)                             AS first_churn_date,
        STRING_AGG(reason_code, ', ')                AS churn_reasons,
        SUM(refund_amount_usd)                       AS total_refunds
    FROM churn_events
    GROUP BY account_id
)
SELECT
    acc.account_id,
    acc.account_name,
    acc.industry,
    acc.country,
    acc.referral_source,
    acc.plan_tier            AS initial_plan_tier,
    acc.seats                AS initial_seats,
    acc.signup_date,
    acc.churn_flag,

    ISNULL(s.total_mrr, 0)             AS total_mrr,
    ISNULL(s.total_arr, 0)             AS total_arr,
    ISNULL(s.max_seats, acc.seats)     AS max_seats,
    ISNULL(s.had_upgrade, 0)           AS had_upgrade,
    ISNULL(s.had_downgrade, 0)         AS had_downgrade,
    ISNULL(s.subscription_count, 0)    AS subscription_count,

    ISNULL(t.total_tickets, 0)         AS total_tickets,
    ISNULL(t.avg_resolution_hours, 0)  AS avg_resolution_hours,
    t.avg_satisfaction,
    ISNULL(t.total_escalations, 0)     AS total_escalations,

    ISNULL(u.total_usage_events, 0)    AS total_usage_events,
    ISNULL(u.total_duration_secs, 0)   AS total_duration_secs,
    ISNULL(u.total_errors, 0)          AS total_errors,
    ISNULL(u.distinct_features_used,0) AS distinct_features_used,
    ISNULL(u.beta_features_used, 0)    AS beta_features_used,

    c.first_churn_date,
    c.churn_reasons,
    ISNULL(c.total_refunds, 0)         AS total_refunds,

    CAST(NULL AS NVARCHAR(20))         AS business_risk_tier   -- populated in the next step

INTO fact_account_summary
FROM accounts acc
LEFT JOIN sub_agg    s ON acc.account_id = s.account_id
LEFT JOIN ticket_agg t ON acc.account_id = t.account_id
LEFT JOIN usage_agg  u ON acc.account_id = u.account_id
LEFT JOIN churn_agg  c ON acc.account_id = c.account_id;
GO

ALTER TABLE fact_account_summary ALTER COLUMN account_id NVARCHAR(50) NOT NULL;
ALTER TABLE fact_account_summary ADD CONSTRAINT PK_fact_account_summary PRIMARY KEY (account_id);
GO


-- =====================================================================
-- 11. Populate business_risk_tier using thresholds derived from the actual data distribution
--     (final version without the disabled escalation condition)
-- =====================================================================
DECLARE
    @satisfaction_p10   FLOAT,
    @satisfaction_p50   FLOAT,
    @escalations_p90    FLOAT;

SELECT @satisfaction_p10 = v FROM (
    SELECT TOP 1 PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY avg_satisfaction) OVER () AS v
    FROM fact_account_summary WHERE avg_satisfaction IS NOT NULL
) x;

SELECT @satisfaction_p50 = v FROM (
    SELECT TOP 1 PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY avg_satisfaction) OVER () AS v
    FROM fact_account_summary WHERE avg_satisfaction IS NOT NULL
) x;

SELECT @escalations_p90 = v FROM (
    SELECT TOP 1 PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY total_escalations) OVER () AS v
    FROM fact_account_summary
) x;

UPDATE fact_account_summary
SET business_risk_tier =
    CASE
        WHEN ISNULL(avg_satisfaction, 99) <= @satisfaction_p10
             OR total_escalations >= @escalations_p90
        THEN 'High Risk'

        WHEN ISNULL(avg_satisfaction, 99) <= @satisfaction_p50
        THEN 'Medium Risk'

        ELSE 'Low Risk'
    END;
GO


-- =====================================================================
-- 12. Final validation: confirm that all tables were built with expected row counts
-- =====================================================================
SELECT 'dim_account' AS table_name, COUNT(*) AS row_count FROM dim_account
UNION ALL SELECT 'dim_date', COUNT(*) FROM dim_date
UNION ALL SELECT 'dim_industry', COUNT(*) FROM dim_industry
UNION ALL SELECT 'dim_plan_tier', COUNT(*) FROM dim_plan_tier
UNION ALL SELECT 'dim_referral_source', COUNT(*) FROM dim_referral_source
UNION ALL SELECT 'dim_reason_code', COUNT(*) FROM dim_reason_code
UNION ALL SELECT 'fact_subscriptions', COUNT(*) FROM fact_subscriptions
UNION ALL SELECT 'fact_feature_usage', COUNT(*) FROM fact_feature_usage
UNION ALL SELECT 'fact_support_tickets', COUNT(*) FROM fact_support_tickets
UNION ALL SELECT 'fact_churn_events', COUNT(*) FROM fact_churn_events
UNION ALL SELECT 'fact_account_summary', COUNT(*) FROM fact_account_summary;

PRINT '✅ الـ Star Schema اتبنى بالكامل بنجاح.';
