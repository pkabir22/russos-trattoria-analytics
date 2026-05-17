-- MARCUS MOVING CO. — WORKFORCE ATTRITION ANALYSIS
-- Snowflake Setup + Staging + Mart Layer
 
-- 0. SETUP 

CREATE DATABASE IF NOT EXISTS MARCUS_MOVING_DB;
USE DATABASE MARCUS_MOVING_DB;
 
CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS STAGING;
CREATE SCHEMA IF NOT EXISTS MARTS;
 
-- 1. RAW TABLES table 
USE SCHEMA RAW;
 
CREATE OR REPLACE TABLE employees (
    employee_id       INTEGER,
    name              VARCHAR,
    role              VARCHAR,
    department        VARCHAR,
    hire_date         VARCHAR,
    termination_date  VARCHAR,
    termination_type  VARCHAR,
    hourly_rate       FLOAT,
    manager_id        VARCHAR,
    status            VARCHAR
);
 
CREATE OR REPLACE TABLE exit_records (
    employee_id         INTEGER,
    exit_date           VARCHAR,
    exit_reason         VARCHAR,
    exit_survey_score   INTEGER,
    eligible_for_rehire VARCHAR,
    manager_id          VARCHAR
);
 
CREATE OR REPLACE TABLE attendance_monthly (
    employee_id     INTEGER,
    month           VARCHAR,
    days_worked     INTEGER,
    days_absent     INTEGER,
    overtime_hours  INTEGER,
    late_arrivals   INTEGER
);
 
CREATE OR REPLACE TABLE performance_reviews (
    employee_id         INTEGER,
    review_period       VARCHAR,
    score               FLOAT,
    promoted            VARCHAR,
    manager_notes_tag   VARCHAR
);


-- 2. STAGING LAYER

USE SCHEMA STAGING;
 
-- stg_employees table 

CREATE OR REPLACE VIEW stg_employees AS
SELECT
    employee_id,
    TRIM(name)                                          AS name,
    TRIM(role)                                          AS role,
    TRIM(department)                                    AS department,
    TRY_TO_DATE(hire_date)                              AS hire_date,
    TRY_TO_DATE(termination_date)                       AS termination_date,
    TRIM(termination_type)                              AS termination_type,
    ROUND(hourly_rate, 2)                               AS hourly_rate,
    TRY_TO_NUMBER(manager_id)                           AS manager_id,
    TRIM(status)                                        AS status,
    -- derived
    CASE WHEN status = 'Terminated' THEN 1 ELSE 0 END  AS is_terminated,
    DATEDIFF('day', TRY_TO_DATE(hire_date),
        COALESCE(TRY_TO_DATE(termination_date), CURRENT_DATE)) AS tenure_days
FROM RAW.employees;
 
-- stg_exit_records table 

CREATE OR REPLACE VIEW stg_exit_records AS
SELECT
    employee_id,
    TRY_TO_DATE(exit_date)          AS exit_date,
    TRIM(exit_reason)               AS exit_reason,
    exit_survey_score,
    TRIM(eligible_for_rehire)       AS eligible_for_rehire,
    TRY_TO_NUMBER(manager_id)       AS manager_id,
    -- derived
    CASE
        WHEN exit_reason ILIKE '%involuntary%' THEN 'Involuntary'
        ELSE 'Voluntary'
    END                             AS exit_category,
    MONTH(TRY_TO_DATE(exit_date))   AS exit_month,
    YEAR(TRY_TO_DATE(exit_date))    AS exit_year,
    QUARTER(TRY_TO_DATE(exit_date)) AS exit_quarter
FROM RAW.exit_records;
 
-- stg_attendance_monthly table 

CREATE OR REPLACE VIEW stg_attendance_monthly AS
SELECT
    employee_id,
    TRY_TO_DATE(month)                                          AS month,
    YEAR(TRY_TO_DATE(month))                                    AS year,
    MONTH(TRY_TO_DATE(month))                                   AS month_num,
    days_worked,
    days_absent,
    overtime_hours,
    late_arrivals,
    -- derived
    ROUND(days_absent / NULLIF(days_worked + days_absent, 0), 4) AS absence_rate,
    CASE WHEN overtime_hours >= 15 THEN 1 ELSE 0 END             AS high_overtime_flag
FROM RAW.attendance_monthly;
 
-- stg_performance_reviews table 

CREATE OR REPLACE VIEW stg_performance_reviews AS
SELECT
    employee_id,
    TRIM(review_period)     AS review_period,
    score,
    TRIM(manager_notes_tag) AS manager_notes_tag,
    CASE WHEN UPPER(promoted) = 'TRUE' THEN 1 ELSE 0 END AS promoted,
    -- derive review date from period label
    CASE
        WHEN review_period ILIKE '%-H1' THEN TRY_TO_DATE(SUBSTR(review_period,1,4) || '-06-30')
        WHEN review_period ILIKE '%-H2' THEN TRY_TO_DATE(SUBSTR(review_period,1,4) || '-12-31')
    END                     AS review_date,
    LEFT(review_period, 4)::INTEGER AS review_year
FROM RAW.performance_reviews;


-- 3. MART LAYER

USE SCHEMA MARTS;
 
-- mart_employee_attrition table 
-- One row per employee ever. Core attrition fact table.

CREATE OR REPLACE VIEW mart_employee_attrition AS
WITH latest_review AS (
    SELECT
        employee_id,
        score       AS last_review_score,
        manager_notes_tag AS last_review_tag
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY review_date DESC) AS rn
        FROM STAGING.stg_performance_reviews
    ) WHERE rn = 1
),
avg_attendance AS (
    SELECT
        employee_id,
        ROUND(AVG(overtime_hours), 1)   AS avg_monthly_ot,
        ROUND(AVG(absence_rate), 4)     AS avg_absence_rate,
        ROUND(AVG(late_arrivals), 1)    AS avg_late_arrivals
    FROM STAGING.stg_attendance_monthly
    GROUP BY 1
)
SELECT
    e.employee_id,
    e.name,
    e.role,
    e.department,
    e.hire_date,
    e.termination_date,
    e.termination_type,
    e.hourly_rate,
    e.manager_id,
    e.status,
    e.is_terminated,
    e.tenure_days,
    ROUND(e.tenure_days / 30.0, 1)          AS tenure_months,
    CASE
        WHEN e.tenure_days < 90   THEN '0-3 months'
        WHEN e.tenure_days < 180  THEN '3-6 months'
        WHEN e.tenure_days < 365  THEN '6-12 months'
        WHEN e.tenure_days < 730  THEN '1-2 years'
        WHEN e.tenure_days < 1095 THEN '2-3 years'
        ELSE '3+ years'
    END                                     AS tenure_band,
    x.exit_reason,
    x.exit_category,
    x.exit_survey_score,
    x.eligible_for_rehire,
    x.exit_month,
    x.exit_year,
    lr.last_review_score,
    lr.last_review_tag,
    aa.avg_monthly_ot,
    aa.avg_absence_rate,
    aa.avg_late_arrivals
FROM STAGING.stg_employees e
LEFT JOIN STAGING.stg_exit_records    x  ON e.employee_id = x.employee_id
LEFT JOIN latest_review               lr ON e.employee_id = lr.employee_id
LEFT JOIN avg_attendance              aa ON e.employee_id = aa.employee_id;

-- mart_monthly_attrition_trend table 

CREATE OR REPLACE VIEW mart_monthly_attrition_trend AS
SELECT
    x.exit_year,
    x.exit_month,
    x.exit_category,
    COUNT(*)                                           AS exits,
    ROUND(AVG(x.exit_survey_score), 2)                AS avg_exit_survey_score,
    ROUND(AVG(e.tenure_days), 0)                      AS avg_tenure_days_at_exit
FROM STAGING.stg_exit_records x
JOIN STAGING.stg_employees e ON x.employee_id = e.employee_id
GROUP BY 1, 2, 3;

-- mart_manager_scorecard table 

CREATE OR REPLACE VIEW mart_manager_scorecard AS
SELECT
    e.manager_id,
    m.name                                             AS manager_name,
    COUNT(*)                                           AS team_size,
    SUM(e.is_terminated)                               AS total_terminations,
    ROUND(SUM(e.is_terminated) / NULLIF(COUNT(*), 0), 4) AS attrition_rate,
    ROUND(AVG(aa.avg_absence_rate), 4)                 AS team_avg_absence_rate,
    ROUND(AVG(aa.avg_monthly_ot), 1)                   AS team_avg_monthly_ot,
    ROUND(AVG(pr.score), 2)                            AS team_avg_review_score,
    ROUND(AVG(x.exit_survey_score), 2)                 AS team_avg_exit_survey
FROM STAGING.stg_employees e
LEFT JOIN STAGING.stg_employees m ON e.manager_id = m.employee_id
LEFT JOIN (
    SELECT employee_id, ROUND(AVG(absence_rate), 4) AS avg_absence_rate, ROUND(AVG(overtime_hours), 1) AS avg_monthly_ot
    FROM STAGING.stg_attendance_monthly
    GROUP BY 1
) aa ON e.employee_id = aa.employee_id
LEFT JOIN STAGING.stg_performance_reviews pr ON e.employee_id = pr.employee_id
LEFT JOIN STAGING.stg_exit_records x ON e.employee_id = x.employee_id
WHERE e.manager_id IS NOT NULL
GROUP BY 1, 2;

-- mart_flight_risk_signals table 

CREATE OR REPLACE VIEW mart_flight_risk_signals AS
WITH avg_att AS (
    SELECT
        employee_id,
        ROUND(AVG(absence_rate), 4)   AS avg_absence_rate,
        ROUND(AVG(overtime_hours), 1) AS avg_monthly_ot,
        ROUND(AVG(late_arrivals), 1)  AS avg_late_arrivals
    FROM STAGING.stg_attendance_monthly
    GROUP BY 1
),
latest_review AS (
    SELECT employee_id, score AS last_review_score
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY review_date DESC) AS rn
        FROM STAGING.stg_performance_reviews
    ) WHERE rn = 1
)
SELECT
    e.employee_id,
    e.name,
    e.role,
    e.department,
    e.manager_id,
    e.tenure_days,
    lr.last_review_score,
    aa.avg_absence_rate,
    aa.avg_monthly_ot,
    aa.avg_late_arrivals,
    CASE
        WHEN lr.last_review_score < 3 THEN 1 ELSE 0
    END AS low_review_flag,
    CASE
        WHEN aa.avg_absence_rate > 0.10 THEN 1 ELSE 0
    END AS high_absence_flag,
    CASE
        WHEN aa.avg_monthly_ot > 20 THEN 1 ELSE 0
    END AS high_ot_flag,
    (CASE WHEN lr.last_review_score < 3 THEN 1 ELSE 0 END
   + CASE WHEN aa.avg_absence_rate > 0.10 THEN 1 ELSE 0 END
   + CASE WHEN aa.avg_monthly_ot > 20 THEN 1 ELSE 0 END) AS risk_signal_count
FROM STAGING.stg_employees e
LEFT JOIN latest_review lr ON e.employee_id = lr.employee_id
LEFT JOIN avg_att aa ON e.employee_id = aa.employee_id
WHERE e.status != 'Terminated';


USE DATABASE MARCUS_MOVING_DB;
USE SCHEMA MARTS;

-- mart_employee_attrition table

CREATE OR REPLACE VIEW mart_employee_attrition AS
WITH latest_review AS (
    SELECT
        employee_id,
        score       AS last_review_score,
        manager_notes_tag AS last_review_tag
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY review_date DESC) AS rn
        FROM STAGING.stg_performance_reviews
    ) WHERE rn = 1
),
avg_attendance AS (
    SELECT
        employee_id,
        ROUND(AVG(overtime_hours), 1)   AS avg_monthly_ot,
        ROUND(AVG(absence_rate), 4)     AS avg_absence_rate,
        ROUND(AVG(late_arrivals), 1)    AS avg_late_arrivals
    FROM STAGING.stg_attendance_monthly
    GROUP BY 1
)
SELECT
    e.employee_id,
    e.name,
    e.role,
    e.department,
    e.hire_date,
    e.termination_date,
    e.termination_type,
    e.hourly_rate,
    e.manager_id,
    e.status,
    e.is_terminated,
    e.tenure_days,
    ROUND(e.tenure_days / 30.0, 1)          AS tenure_months,
    CASE
        WHEN e.tenure_days < 90   THEN '0-3 months'
        WHEN e.tenure_days < 180  THEN '3-6 months'
        WHEN e.tenure_days < 365  THEN '6-12 months'
        WHEN e.tenure_days < 730  THEN '1-2 years'
        WHEN e.tenure_days < 1095 THEN '2-3 years'
        ELSE '3+ years'
    END                                     AS tenure_band,
    x.exit_reason,
    x.exit_category,
    x.exit_survey_score,
    x.eligible_for_rehire,
    x.exit_month,
    x.exit_year,
    lr.last_review_score,
    lr.last_review_tag,
    aa.avg_monthly_ot,
    aa.avg_absence_rate,
    aa.avg_late_arrivals
FROM STAGING.stg_employees e
LEFT JOIN STAGING.stg_exit_records    x  ON e.employee_id = x.employee_id
LEFT JOIN latest_review               lr ON e.employee_id = lr.employee_id
LEFT JOIN avg_attendance              aa ON e.employee_id = aa.employee_id;

-- mart_monthly_attrition_trend table

CREATE OR REPLACE VIEW mart_monthly_attrition_trend AS
WITH months AS (
    SELECT DISTINCT month AS period_month
    FROM STAGING.stg_attendance_monthly
),
headcount AS (
    SELECT
        m.period_month,
        COUNT(DISTINCT a.employee_id) AS active_headcount
    FROM months m
    JOIN STAGING.stg_attendance_monthly a ON a.month = m.period_month
    GROUP BY 1
),
exits AS (
    SELECT
        DATE_TRUNC('month', exit_date)  AS period_month,
        COUNT(*)                        AS exits_count,
        SUM(CASE WHEN exit_category = 'Voluntary' THEN 1 ELSE 0 END)   AS voluntary_exits,
        SUM(CASE WHEN exit_category = 'Involuntary' THEN 1 ELSE 0 END) AS involuntary_exits
    FROM STAGING.stg_exit_records
    GROUP BY 1
)
SELECT
    h.period_month,
    YEAR(h.period_month)                                        AS year,
    MONTH(h.period_month)                                       AS month_num,
    h.active_headcount,
    COALESCE(e.exits_count, 0)                                  AS exits_count,
    COALESCE(e.voluntary_exits, 0)                              AS voluntary_exits,
    COALESCE(e.involuntary_exits, 0)                            AS involuntary_exits,
    ROUND(COALESCE(e.exits_count, 0) / NULLIF(h.active_headcount, 0), 4) AS monthly_attrition_rate
FROM headcount h
LEFT JOIN exits e ON h.period_month = e.period_month
ORDER BY 1;

-- mart_manager_scorecard table

CREATE OR REPLACE VIEW mart_manager_scorecard AS
WITH mgr_info AS (
    SELECT employee_id AS manager_id, name AS manager_name
    FROM STAGING.stg_employees
    WHERE role = 'Manager'
),
avg_att AS (
    SELECT
        employee_id,
        ROUND(AVG(overtime_hours), 1) AS avg_monthly_ot
    FROM STAGING.stg_attendance_monthly
    GROUP BY 1
),
team_stats AS (
    SELECT
        e.manager_id,
        COUNT(DISTINCT e.employee_id)                               AS team_size,
        SUM(e.is_terminated)                                        AS total_exits,
        ROUND(AVG(CASE WHEN e.is_terminated = 1
            THEN ROUND(e.tenure_days / 30.0, 1) END), 1)           AS avg_tenure_at_exit_months,
        ROUND(SUM(e.is_terminated) / NULLIF(COUNT(DISTINCT e.employee_id),0), 4) AS attrition_rate,
        SUM(CASE WHEN x.exit_reason = 'Burnout' THEN 1 ELSE 0 END) AS burnout_exits,
        ROUND(SUM(CASE WHEN x.exit_reason = 'Burnout' THEN 1 ELSE 0 END)
            / NULLIF(SUM(e.is_terminated), 0), 4)                   AS burnout_rate,
        ROUND(AVG(aa.avg_monthly_ot), 1)                            AS avg_team_ot_hours
    FROM STAGING.stg_employees e
    LEFT JOIN STAGING.stg_exit_records x  ON e.employee_id = x.employee_id
    LEFT JOIN avg_att aa                  ON e.employee_id = aa.employee_id
    WHERE e.manager_id IS NOT NULL
    GROUP BY 1
)
SELECT
    ts.manager_id,
    m.manager_name,
    ts.team_size,
    ts.total_exits,
    ts.avg_tenure_at_exit_months,
    ts.attrition_rate,
    ts.burnout_exits,
    ts.burnout_rate,
    ts.avg_team_ot_hours,
    CASE
        WHEN ts.attrition_rate >= 0.60 THEN 'High Risk'
        WHEN ts.attrition_rate >= 0.40 THEN 'Watch'
        ELSE 'Healthy'
    END AS team_health_flag
FROM team_stats ts
LEFT JOIN mgr_info m ON ts.manager_id = m.manager_id
ORDER BY ts.attrition_rate DESC;

 
-- mart_flight_risk_signals table

CREATE OR REPLACE VIEW mart_flight_risk_signals AS
WITH review_trend AS (
    SELECT
        employee_id,
        score AS latest_score,
        LAG(score) OVER (PARTITION BY employee_id ORDER BY review_date) AS prev_score,
        ROW_NUMBER() OVER (PARTITION BY employee_id ORDER BY review_date DESC) AS rn
    FROM STAGING.stg_performance_reviews
),
score_delta AS (
    SELECT
        employee_id,
        MAX(latest_score)                                AS latest_score,
        MAX(latest_score) - MAX(COALESCE(prev_score, 0)) AS score_delta
    FROM review_trend
    WHERE rn <= 2
    GROUP BY 1
),
recent_attendance AS (
    SELECT
        employee_id,
        ROUND(AVG(overtime_hours), 1)  AS recent_avg_ot,
        ROUND(AVG(absence_rate), 4)    AS recent_absence_rate,
        ROUND(AVG(late_arrivals), 1)   AS recent_late_avg
    FROM STAGING.stg_attendance_monthly
    WHERE month >= DATEADD('month', -6, CURRENT_DATE)
    GROUP BY 1
),
base AS (
    SELECT
        e.employee_id,
        e.name,
        e.role,
        e.department,
        e.manager_id,
        ROUND(e.tenure_days / 30.0, 1) AS tenure_months,
        CASE
            WHEN e.tenure_days < 90   THEN '0-3 months'
            WHEN e.tenure_days < 180  THEN '3-6 months'
            WHEN e.tenure_days < 365  THEN '6-12 months'
            WHEN e.tenure_days < 730  THEN '1-2 years'
            WHEN e.tenure_days < 1095 THEN '2-3 years'
            ELSE '3+ years'
        END AS tenure_band,
        e.hourly_rate,
        sd.latest_score         AS current_review_score,
        sd.score_delta          AS review_score_delta,
        ra.recent_avg_ot,
        ra.recent_absence_rate,
        ra.recent_late_avg,
        -- risk score components
        CASE WHEN sd.score_delta < -0.5 THEN 35
             WHEN sd.score_delta < 0    THEN 20
             ELSE 0 END AS score_pts,
        CASE WHEN ra.recent_avg_ot >= 20 THEN 25
             WHEN ra.recent_avg_ot >= 12 THEN 15
             ELSE 0 END AS ot_pts,
        CASE WHEN ROUND(e.tenure_days / 30.0, 1) BETWEEN 12 AND 30 THEN 20
             WHEN ROUND(e.tenure_days / 30.0, 1) < 12              THEN 10
             ELSE 5 END AS tenure_pts,
        CASE WHEN ra.recent_absence_rate >= 0.15 THEN 20
             WHEN ra.recent_absence_rate >= 0.08 THEN 10
             ELSE 0 END AS absence_pts
    FROM STAGING.stg_employees e
    JOIN score_delta sd       ON e.employee_id = sd.employee_id
    JOIN recent_attendance ra ON e.employee_id = ra.employee_id
    WHERE e.status = 'Active'
)
SELECT
    employee_id,
    name,
    role,
    department,
    manager_id,
    tenure_months,
    tenure_band,
    hourly_rate,
    current_review_score,
    review_score_delta,
    recent_avg_ot,
    recent_absence_rate,
    recent_late_avg,
    LEAST(100, score_pts + ot_pts + tenure_pts + absence_pts) AS flight_risk_score,
    CASE
        WHEN LEAST(100, score_pts + ot_pts + tenure_pts + absence_pts) >= 60 THEN 'High'
        WHEN LEAST(100, score_pts + ot_pts + tenure_pts + absence_pts) >= 35 THEN 'Medium'
        ELSE 'Low'
    END AS flight_risk_label
FROM base; 