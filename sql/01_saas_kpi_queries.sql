-- =====================================================================
-- RavenStack - 01_saas_kpi_queries.sql
-- Analytical and reporting queries -- run after 00_setup_star_schema.sql
-- All queries are read-only (SELECT) and safe to execute individually.
-- =====================================================================
USE RavenStack;
GO


-- 1. Executive Overview: Accounts, Churn, MRR/ARR, and ARPA
SELECT
    COUNT(*)                                            AS total_accounts,
    SUM(CASE WHEN churn_flag = 1 THEN 1 ELSE 0 END)     AS churned_accounts,
    CAST(SUM(CASE WHEN churn_flag = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100 AS customer_churn_rate_pct,
    SUM(total_mrr)                                       AS total_mrr_all,
    SUM(total_mrr) * 12                                   AS total_arr_estimate,
    SUM(CASE WHEN churn_flag = 1 THEN total_mrr ELSE 0 END) AS mrr_lost_to_churn,
    CAST(SUM(total_mrr) AS FLOAT) / NULLIF(COUNT(*), 0)   AS arpa
FROM fact_account_summary;


-- 2. Revenue and Churn by Industry
SELECT
    di.industry_name,
    COUNT(*)                                          AS account_count,
    SUM(fs.total_mrr)                                   AS total_mrr,
    AVG(fs.total_mrr)                                   AS avg_mrr_per_account,
    SUM(CASE WHEN fs.churn_flag = 1 THEN 1 ELSE 0 END)  AS churned_count,
    CAST(SUM(CASE WHEN fs.churn_flag = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100 AS churn_rate_pct
FROM fact_account_summary fs
INNER JOIN dim_account da ON fs.account_id = da.account_id
INNER JOIN dim_industry di ON da.industry_id = di.industry_id
GROUP BY di.industry_name
ORDER BY total_mrr DESC;


-- 3. Referral Source Performance
SELECT
    drs.referral_source_name,
    COUNT(*)                                          AS account_count,
    SUM(fs.total_mrr)                                   AS total_mrr,
    SUM(CASE WHEN fs.churn_flag = 1 THEN 1 ELSE 0 END)  AS churned_count,
    CAST(SUM(CASE WHEN fs.churn_flag = 1 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) * 100 AS churn_rate_pct
FROM fact_account_summary fs
INNER JOIN dim_account da ON fs.account_id = da.account_id
INNER JOIN dim_referral_source drs ON da.referral_source_id = drs.referral_source_id
GROUP BY drs.referral_source_name
ORDER BY churn_rate_pct ASC;


-- 4. Most Frequently Used Features
SELECT TOP 15
    feature_name,
    COUNT(*)                          AS usage_events,
    SUM(usage_count)                   AS total_usage_count,
    SUM(usage_duration_secs)           AS total_duration_secs,
    SUM(error_count)                   AS total_errors,
    COUNT(DISTINCT account_id)         AS distinct_accounts_using
FROM fact_feature_usage
GROUP BY feature_name
ORDER BY usage_events DESC;


-- 5. Beta Feature Adoption
SELECT
    is_beta_feature,
    COUNT(*)                       AS usage_events,
    COUNT(DISTINCT account_id)     AS distinct_accounts,
    SUM(error_count)               AS total_errors
FROM fact_feature_usage
GROUP BY is_beta_feature;


-- 6. Support Quality by Priority
SELECT
    priority,
    COUNT(*)                                   AS ticket_count,
    AVG(resolution_time_hours)                  AS avg_resolution_hours,
    AVG(CAST(satisfaction_score AS FLOAT))      AS avg_satisfaction,
    SUM(CASE WHEN escalation_flag = 1 THEN 1 ELSE 0 END) AS escalations,
    AVG(first_response_time_minutes)            AS avg_first_response_min
FROM fact_support_tickets
GROUP BY priority
ORDER BY CASE priority WHEN 'urgent' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 END;


-- 7. Churn Reasons and Financial Impact
SELECT
    drc.reason_code_name,
    COUNT(*)                            AS churn_count,
    SUM(fs.total_mrr)                    AS mrr_lost,
    AVG(fs.total_mrr)                    AS avg_mrr_per_churned_account,
    SUM(ce.refund_amount_usd)            AS total_refunds
FROM fact_churn_events ce
INNER JOIN fact_account_summary fs ON ce.account_id = fs.account_id
LEFT JOIN dim_reason_code drc ON ce.reason_code_id = drc.reason_code_id
GROUP BY drc.reason_code_name
ORDER BY mrr_lost DESC;


-- 8. Upgrade/Downgrade Activity Before Churn
SELECT preceding_upgrade_flag, preceding_downgrade_flag, COUNT(*) AS churn_count
FROM fact_churn_events
GROUP BY preceding_upgrade_flag, preceding_downgrade_flag
ORDER BY churn_count DESC;


-- 9. Account Distribution by Business Risk Tier
SELECT
    business_risk_tier,
    COUNT(*)                       AS account_count,
    SUM(total_mrr)                  AS mrr_in_tier,
    AVG(avg_satisfaction)           AS avg_satisfaction_in_tier,
    SUM(CASE WHEN churn_flag = 1 THEN 1 ELSE 0 END) AS actually_churned
FROM fact_account_summary
GROUP BY business_risk_tier
ORDER BY mrr_in_tier DESC;


-- 10. Monthly MRR Snapshot and Growth Rate
WITH months AS (
    SELECT year_month, MAX(date_key) AS month_end FROM dim_date GROUP BY year_month
),
monthly_mrr AS (
    SELECT m.year_month, SUM(s.mrr_amount) AS active_mrr, COUNT(DISTINCT s.account_id) AS active_accounts
    FROM months m
    INNER JOIN fact_subscriptions s
        ON s.start_date <= m.month_end AND (s.end_date IS NULL OR s.end_date >= m.month_end)
    GROUP BY m.year_month
)
SELECT
    year_month, active_accounts, active_mrr, active_mrr * 12 AS arr_snapshot,
    LAG(active_mrr) OVER (ORDER BY year_month) AS prev_month_mrr,
    active_mrr - LAG(active_mrr) OVER (ORDER BY year_month) AS net_new_mrr,
    CAST(active_mrr - LAG(active_mrr) OVER (ORDER BY year_month) AS FLOAT)
        / NULLIF(LAG(active_mrr) OVER (ORDER BY year_month), 0) * 100 AS mrr_growth_rate_pct
FROM monthly_mrr
ORDER BY year_month;


-- 11. Upgrade/Downgrade Funnel by Plan Tier
SELECT
    dpt.plan_tier_name,
    COUNT(*)                                              AS subscription_count,
    SUM(CASE WHEN s.upgrade_flag = 1 THEN 1 ELSE 0 END)   AS upgrades,
    SUM(CASE WHEN s.downgrade_flag = 1 THEN 1 ELSE 0 END) AS downgrades,
    SUM(CASE WHEN s.churn_flag = 1 THEN 1 ELSE 0 END)     AS churned,
    AVG(s.mrr_amount)                                       AS avg_mrr
FROM fact_subscriptions s
LEFT JOIN dim_plan_tier dpt ON s.plan_tier_id = dpt.plan_tier_id
GROUP BY dpt.plan_tier_name
ORDER BY avg_mrr DESC;


-- 12. Cohort Retention by Signup Month
SELECT
    FORMAT(signup_date, 'yyyy-MM') AS signup_cohort,
    COUNT(account_id)               AS total_cohort_accounts,
    SUM(CASE WHEN churn_flag = 0 THEN 1 ELSE 0 END) AS active_retained_accounts,
    CAST(SUM(CASE WHEN churn_flag = 0 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(account_id) * 100 AS retention_rate_pct
FROM fact_account_summary
GROUP BY FORMAT(signup_date, 'yyyy-MM')
ORDER BY signup_cohort;


-- 13. Feature Usage: Churned vs. Retained Accounts
SELECT
    f.churn_flag,
    COUNT(DISTINCT f.account_id) AS total_accounts,
    AVG(u.total_usage_events)     AS avg_usage_events,
    AVG(u.total_errors)           AS avg_errors,
    CAST(SUM(u.total_errors) AS FLOAT) / (SUM(u.total_usage_events) + 1) AS error_rate_per_event
FROM fact_account_summary f
LEFT JOIN (
    SELECT account_id, COUNT(*) AS total_usage_events, SUM(error_count) AS total_errors
    FROM fact_feature_usage GROUP BY account_id
) u ON f.account_id = u.account_id
GROUP BY f.churn_flag;


-- 14. Support Quality and Its Relationship with Churn
SELECT
    f.churn_flag,
    AVG(t.resolution_time_hours)                AS avg_resolution_hours,
    AVG(CAST(t.satisfaction_score AS FLOAT))    AS avg_satisfaction,
    SUM(CASE WHEN t.escalation_flag = 1 THEN 1 ELSE 0 END) AS total_escalations
FROM fact_account_summary f
INNER JOIN fact_support_tickets t ON f.account_id = t.account_id
GROUP BY f.churn_flag;


-- 15. MRR at Risk by Business Risk Tier (Active Accounts Only)
SELECT
    business_risk_tier,
    COUNT(account_id)      AS accounts_count,
    SUM(total_mrr)           AS total_mrr_at_risk,
    AVG(avg_satisfaction)    AS avg_satisfaction
FROM fact_account_summary
WHERE churn_flag = 0
GROUP BY business_risk_tier
ORDER BY total_mrr_at_risk DESC;


-- 16. MRR Movement (New / Expansion / Contraction) -- approximate; see note below
WITH first_sub AS (
    SELECT account_id, MIN(start_date) AS first_start_date FROM fact_subscriptions GROUP BY account_id
)
SELECT
    FORMAT(s.start_date, 'yyyy-MM') AS movement_month,
    SUM(CASE WHEN s.start_date = fs.first_start_date THEN s.mrr_amount ELSE 0 END) AS new_mrr,
    SUM(CASE WHEN s.start_date != fs.first_start_date AND s.upgrade_flag = 1 THEN s.mrr_amount ELSE 0 END) AS expansion_mrr,
    SUM(CASE WHEN s.start_date != fs.first_start_date AND s.downgrade_flag = 1 THEN s.mrr_amount ELSE 0 END) AS contraction_mrr
FROM fact_subscriptions s
INNER JOIN first_sub fs ON s.account_id = fs.account_id
GROUP BY FORMAT(s.start_date, 'yyyy-MM')
ORDER BY movement_month;
-- Note: Expansion/Contraction are approximate because the full mrr_amount
-- is attributed to subscriptions with an upgrade/downgrade, rather than the exact price difference.
-- Historical pricing data is not available.


-- 17. Monthly Gross Revenue Retention (GRR)
WITH months AS (
    SELECT year_month, MAX(date_key) AS month_end FROM dim_date GROUP BY year_month
),
monthly_snapshot AS (
    SELECT m.year_month, SUM(s.mrr_amount) AS starting_mrr
    FROM months m
    INNER JOIN fact_subscriptions s
        ON s.start_date <= m.month_end AND (s.end_date IS NULL OR s.end_date >= m.month_end)
    GROUP BY m.year_month
),
churned_by_month AS (
    SELECT FORMAT(end_date, 'yyyy-MM') AS ym, SUM(mrr_amount) AS churned_mrr
    FROM fact_subscriptions WHERE churn_flag = 1 AND end_date IS NOT NULL
    GROUP BY FORMAT(end_date, 'yyyy-MM')
)
SELECT
    ms.year_month, ms.starting_mrr, ISNULL(cbm.churned_mrr, 0) AS churned_mrr,
    (1 - CAST(ISNULL(cbm.churned_mrr, 0) AS FLOAT) / NULLIF(ms.starting_mrr, 0)) * 100 AS gross_revenue_retention_pct
FROM monthly_snapshot ms
LEFT JOIN churned_by_month cbm ON ms.year_month = cbm.ym
ORDER BY ms.year_month;


-- 18. Customer Lifetime Value (LTV) -- corrected version
-- (A) Formula-based LTV using a correctly calculated average monthly churn rate
DECLARE @arpa FLOAT, @correct_monthly_churn FLOAT;

SELECT @arpa = CAST(SUM(total_mrr) AS FLOAT) / NULLIF(COUNT(*), 0)
FROM fact_account_summary WHERE churn_flag = 0;

;WITH months AS (
    SELECT year_month, MAX(date_key) AS month_end FROM dim_date GROUP BY year_month
),
active_start_of_month AS (
    SELECT m.year_month, COUNT(DISTINCT s.account_id) AS active_accounts_start
    FROM months m
    INNER JOIN fact_subscriptions s
        ON s.start_date <= m.month_end AND (s.end_date IS NULL OR s.end_date >= m.month_end)
    GROUP BY m.year_month
),
churned_in_month AS (
    SELECT FORMAT(end_date, 'yyyy-MM') AS ym, COUNT(DISTINCT account_id) AS churned_accounts
    FROM fact_subscriptions WHERE churn_flag = 1 AND end_date IS NOT NULL
    GROUP BY FORMAT(end_date, 'yyyy-MM')
)
SELECT @correct_monthly_churn = AVG(CAST(ISNULL(c.churned_accounts, 0) AS FLOAT) / NULLIF(a.active_accounts_start, 0))
FROM active_start_of_month a
LEFT JOIN churned_in_month c ON a.year_month = c.ym;

SELECT
    @arpa AS arpa,
    @correct_monthly_churn AS correct_monthly_churn_rate,
    @arpa / NULLIF(@correct_monthly_churn, 0) AS ltv_formula_based;

-- (B) Empirical LTV: average realized revenue from churned accounts
-- (closer to observed results; use this version in the final report instead of A)
SELECT AVG(realized_revenue) AS ltv_empirical_churned_accounts
FROM (
    SELECT s.account_id,
        SUM(s.mrr_amount * (CAST(ISNULL(s.subscription_duration_days, 0) AS FLOAT) / 30.0)) AS realized_revenue
    FROM fact_subscriptions s WHERE s.churn_flag = 1
    GROUP BY s.account_id
) t;


-- 19. Customer Acquisition Cost (CAC) -- cannot be calculated from the available data
-- The schema does not include sales or marketing spend. If this data becomes available:
-- CAC = Total Sales & Marketing Spend / Number of New Customers in the Same Period


-- 20. Trial-to-Paid Conversion Rate
WITH trial_accounts AS (
    SELECT DISTINCT account_id FROM fact_subscriptions WHERE is_trial = 1
),
converted_accounts AS (
    SELECT DISTINCT s.account_id FROM fact_subscriptions s
    INNER JOIN trial_accounts t ON s.account_id = t.account_id
    WHERE s.is_trial = 0
)
SELECT
    (SELECT COUNT(*) FROM trial_accounts)     AS total_ever_trialed,
    (SELECT COUNT(*) FROM converted_accounts) AS converted_to_paid,
    CAST((SELECT COUNT(*) FROM converted_accounts) AS FLOAT)
        / NULLIF((SELECT COUNT(*) FROM trial_accounts), 0) * 100 AS trial_to_paid_conversion_pct;
-- Note: If the result is 100%, this is likely a characteristic of the synthetic
-- data generation process (every account transitions to paid), rather than a real business result.


-- 21. Monthly SaaS Quick Ratio (Growth Efficiency)
WITH first_sub AS (
    SELECT account_id, MIN(start_date) AS first_start_date FROM fact_subscriptions GROUP BY account_id
),
movement AS (
    SELECT
        FORMAT(s.start_date, 'yyyy-MM') AS ym,
        SUM(CASE WHEN s.start_date = fs.first_start_date THEN s.mrr_amount ELSE 0 END) AS new_mrr,
        SUM(CASE WHEN s.start_date != fs.first_start_date AND s.upgrade_flag = 1 THEN s.mrr_amount ELSE 0 END) AS expansion_mrr,
        SUM(CASE WHEN s.start_date != fs.first_start_date AND s.downgrade_flag = 1 THEN s.mrr_amount ELSE 0 END) AS contraction_mrr
    FROM fact_subscriptions s
    INNER JOIN first_sub fs ON s.account_id = fs.account_id
    GROUP BY FORMAT(s.start_date, 'yyyy-MM')
),
churn AS (
    SELECT FORMAT(end_date, 'yyyy-MM') AS ym, SUM(mrr_amount) AS churned_mrr
    FROM fact_subscriptions WHERE churn_flag = 1 AND end_date IS NOT NULL
    GROUP BY FORMAT(end_date, 'yyyy-MM')
)
SELECT
    m.ym, m.new_mrr, m.expansion_mrr, m.contraction_mrr, ISNULL(c.churned_mrr, 0) AS churned_mrr,
    CAST(m.new_mrr + m.expansion_mrr AS FLOAT) / NULLIF(ISNULL(c.churned_mrr, 0) + m.contraction_mrr, 0) AS quick_ratio
FROM movement m
LEFT JOIN churn c ON m.ym = c.ym
ORDER BY m.ym;


-- 22. ARPA by Current Plan Tier (Latest Subscription per Account -- corrected version)
WITH latest_sub AS (
    SELECT account_id, plan_tier_id,
        ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY start_date DESC) AS rn
    FROM fact_subscriptions
)
SELECT
    dpt.plan_tier_name,
    COUNT(DISTINCT fs.account_id)                        AS accounts,
    SUM(fs.total_mrr)                                      AS total_mrr,
    CAST(SUM(fs.total_mrr) AS FLOAT) / NULLIF(COUNT(DISTINCT fs.account_id), 0) AS arpa
FROM fact_account_summary fs
INNER JOIN latest_sub ls ON fs.account_id = ls.account_id AND ls.rn = 1
LEFT JOIN dim_plan_tier dpt ON ls.plan_tier_id = dpt.plan_tier_id
GROUP BY dpt.plan_tier_name
ORDER BY arpa DESC;
