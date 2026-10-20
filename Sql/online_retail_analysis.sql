-- =====================================================================
-- ONLINE RETAIL SALES & CUSTOMER PERFORMANCE ANALYSIS
-- Portfolio SQL Script
-- Platform: Google BigQuery (Standard SQL)
-- Project: online-retail-analytics-511409
-- Dataset: online_retail
-- Source: UCI Online Retail
-- =====================================================================
-- This script consolidates the principal SQL used across PREPARE,
-- PROCESS and ANALYZE. It preserves the KPI definitions used in the
-- Power BI dashboard and final case-study documentation.
--
-- Key definitions:
-- Net Revenue = Customer Sale value + Cancellation value
-- Orders = distinct invoices containing at least one Customer Sale
-- Customers = identifiable customers with at least one Customer Sale
-- Units Sold = Quantity on Customer Sale rows
-- AOV = Net Revenue / Total Sales Orders
--
-- Important limitations:
-- December 2011 is partial through 9 December.
-- Customer analysis excludes transactions with missing CustomerID.
-- Net Revenue is revenue, not profit.
-- =====================================================================


-- =====================================================================
-- 1. PREPARE — DATA PROFILING
-- =====================================================================

-- 1.1 Dataset overview
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT InvoiceNo) AS distinct_invoices,
  COUNT(DISTINCT CustomerID) AS identifiable_customers,
  COUNT(DISTINCT StockCode) AS distinct_stock_codes,
  COUNT(DISTINCT Country) AS distinct_countries
FROM `online-retail-analytics-511409.online_retail.raw_transactions`;

-- Validated: 541,909 rows; 25,900 invoices; 4,372 identifiable
-- customers; 4,070 StockCodes; 38 countries.


-- 1.2 Missing values
SELECT
  COUNTIF(Description IS NULL) AS missing_description,
  COUNTIF(CustomerID IS NULL) AS missing_customer_id,
  COUNTIF(InvoiceNo IS NULL) AS missing_invoice_no,
  COUNTIF(StockCode IS NULL) AS missing_stock_code,
  COUNTIF(Quantity IS NULL) AS missing_quantity,
  COUNTIF(InvoiceDate IS NULL) AS missing_invoice_date,
  COUNTIF(UnitPrice IS NULL) AS missing_unit_price,
  COUNTIF(Country IS NULL) AS missing_country
FROM `online-retail-analytics-511409.online_retail.raw_transactions`;

-- Validated: Description = 1,454; CustomerID = 135,080 (~24.93%).


-- 1.3 Quantity profile
SELECT
  MIN(Quantity) AS min_quantity,
  MAX(Quantity) AS max_quantity,
  AVG(Quantity) AS avg_quantity,
  COUNTIF(Quantity > 0) AS positive_quantity_rows,
  COUNTIF(Quantity = 0) AS zero_quantity_rows,
  COUNTIF(Quantity < 0) AS negative_quantity_rows
FROM `online-retail-analytics-511409.online_retail.raw_transactions`;

-- Validated: min -80,995; max 80,995; positive 531,285;
-- zero 0; negative 10,624.


-- 1.4 UnitPrice profile
SELECT
  MIN(UnitPrice) AS min_unit_price,
  MAX(UnitPrice) AS max_unit_price,
  AVG(UnitPrice) AS avg_unit_price,
  COUNTIF(UnitPrice > 0) AS positive_price_rows,
  COUNTIF(UnitPrice = 0) AS zero_price_rows,
  COUNTIF(UnitPrice < 0) AS negative_price_rows
FROM `online-retail-analytics-511409.online_retail.raw_transactions`;

-- Validated: min -11,062.06; max 38,970; zero-price 2,515;
-- negative-price 2.


-- 1.5 Cancellation and negative-quantity profile
SELECT
  COUNTIF(STARTS_WITH(InvoiceNo, 'C')) AS cancellation_rows,
  COUNT(DISTINCT IF(STARTS_WITH(InvoiceNo, 'C'), InvoiceNo, NULL))
    AS cancellation_invoices,
  COUNTIF(Quantity < 0 AND NOT STARTS_WITH(InvoiceNo, 'C'))
    AS negative_quantity_without_c_code
FROM `online-retail-analytics-511409.online_retail.raw_transactions`;

-- Validated: 9,288 cancellation rows; 3,836 cancellation invoices;
-- 1,336 negative-quantity rows without C-code.


-- 1.6 Investigate negative quantities without cancellation code
SELECT
  InvoiceNo, StockCode, Description, Quantity,
  UnitPrice, CustomerID, Country
FROM `online-retail-analytics-511409.online_retail.raw_transactions`
WHERE Quantity < 0
  AND NOT STARTS_WITH(InvoiceNo, 'C')
ORDER BY Quantity;

-- Finding: all 1,336 had UnitPrice = 0 and CustomerID = NULL.
-- Classified as Operational Adjustment.


-- 1.7 Negative UnitPrice / bad debt investigation
SELECT
  InvoiceNo, StockCode, Description, Quantity,
  UnitPrice, CustomerID, Country
FROM `online-retail-analytics-511409.online_retail.raw_transactions`
WHERE UnitPrice < 0
ORDER BY UnitPrice;

SELECT
  InvoiceNo, StockCode, Description, Quantity,
  UnitPrice, CustomerID, Country
FROM `online-retail-analytics-511409.online_retail.raw_transactions`
WHERE Description = 'Adjust bad debt'
ORDER BY InvoiceNo;

-- Three bad-debt records were identified; two carry negative UnitPrice.


-- 1.8 Zero-price profile
SELECT
  COUNT(*) AS zero_price_rows,
  COUNTIF(CustomerID IS NULL) AS missing_customer_id,
  COUNTIF(CustomerID IS NOT NULL) AS identified_customer_id,
  COUNTIF(Quantity > 0) AS positive_quantity,
  COUNTIF(Quantity < 0) AS negative_quantity,
  COUNTIF(Description IS NULL) AS missing_description
FROM `online-retail-analytics-511409.online_retail.raw_transactions`
WHERE UnitPrice = 0;

-- Validated: 2,515 zero-price rows; 2,475 missing CustomerID;
-- 40 identified CustomerID; 1,179 positive quantity;
-- 1,336 negative quantity; 1,454 missing Description.


-- 1.9 Potential full-row duplicates
SELECT
  SUM(row_count - 1) AS potential_duplicate_rows
FROM (
  SELECT
    InvoiceNo, StockCode, Description, Quantity, InvoiceDate,
    UnitPrice, CustomerID, Country,
    COUNT(*) AS row_count
  FROM `online-retail-analytics-511409.online_retail.raw_transactions`
  GROUP BY
    InvoiceNo, StockCode, Description, Quantity, InvoiceDate,
    UnitPrice, CustomerID, Country
  HAVING COUNT(*) > 1
);

-- Validated: 5,268 potential duplicate rows.
-- Retained because the source lacks a unique transaction-line identifier.


-- 1.10 Date validation
SELECT
  COUNTIF(SAFE.PARSE_DATETIME('%d/%m/%Y %H:%M', InvoiceDate) IS NULL)
    AS unparseable_dates,
  MIN(SAFE.PARSE_DATETIME('%d/%m/%Y %H:%M', InvoiceDate)) AS earliest_date,
  MAX(SAFE.PARSE_DATETIME('%d/%m/%Y %H:%M', InvoiceDate)) AS latest_date
FROM `online-retail-analytics-511409.online_retail.raw_transactions`;

-- Validated: 0 unparseable; 2010-12-01 08:26 to 2011-12-09 12:50.


-- =====================================================================
-- 2. PROCESS — ANALYSIS-READY VIEW
-- =====================================================================

CREATE OR REPLACE VIEW
`online-retail-analytics-511409.online_retail.processed_transactions` AS
SELECT
  InvoiceNo,
  StockCode,
  Description,
  Quantity,
  PARSE_DATETIME('%d/%m/%Y %H:%M', InvoiceDate) AS InvoiceDate,
  UnitPrice,
  CustomerID,
  Country,
  Quantity * UnitPrice AS LineValue,

  CASE
    WHEN STARTS_WITH(InvoiceNo, 'C')
      THEN 'Cancellation'
    WHEN Description = 'Adjust bad debt'
      THEN 'Bad Debt Adjustment'
    WHEN Quantity < 0
         AND NOT STARTS_WITH(InvoiceNo, 'C')
         AND UnitPrice = 0
      THEN 'Operational Adjustment'
    WHEN Quantity > 0
         AND UnitPrice = 0
         AND CustomerID IS NOT NULL
      THEN 'Zero-Price Customer Transaction'
    WHEN Quantity > 0
         AND UnitPrice = 0
         AND CustomerID IS NULL
      THEN 'Zero-Price Non-Customer Record'
    WHEN Quantity > 0
         AND UnitPrice > 0
      THEN 'Customer Sale'
    ELSE 'Unclassified'
  END AS TransactionType,

  DATE(PARSE_DATETIME('%d/%m/%Y %H:%M', InvoiceDate))
    AS TransactionDate,
  EXTRACT(YEAR FROM PARSE_DATETIME('%d/%m/%Y %H:%M', InvoiceDate))
    AS TransactionYear,
  EXTRACT(MONTH FROM PARSE_DATETIME('%d/%m/%Y %H:%M', InvoiceDate))
    AS TransactionMonth
FROM `online-retail-analytics-511409.online_retail.raw_transactions`;


-- 2.1 Validate transaction classification
SELECT
  TransactionType,
  COUNT(*) AS rows
FROM `online-retail-analytics-511409.online_retail.processed_transactions`
GROUP BY TransactionType
ORDER BY rows DESC;

-- Customer Sale                      530,103
-- Cancellation                        9,288
-- Operational Adjustment              1,336
-- Zero-Price Non-Customer Record       1,139
-- Zero-Price Customer Transaction         40
-- Bad Debt Adjustment                      3


-- =====================================================================
-- 3. ANALYZE — CORE COMMERCIAL KPIs
-- =====================================================================

-- 3.1 Customer Sale population
SELECT
  COUNT(*) AS sales_lines,
  COUNT(DISTINCT InvoiceNo) AS sales_orders,
  COUNT(DISTINCT CustomerID) AS identifiable_sales_customers,
  SUM(Quantity) AS units_sold,
  SUM(LineValue) AS gross_sales
FROM `online-retail-analytics-511409.online_retail.processed_transactions`
WHERE TransactionType = 'Customer Sale';

-- Validated:
-- 530,103 sales lines
-- 19,959 sales orders
-- 4,338 identifiable sales customers
-- 5,588,375 units
-- £10,655,622.484 gross sales


-- 3.2 Cancellation metrics
SELECT
  COUNT(DISTINCT InvoiceNo) AS cancellation_invoices,
  SUM(Quantity) AS cancelled_units,
  SUM(LineValue) AS cancellation_value
FROM `online-retail-analytics-511409.online_retail.processed_transactions`
WHERE TransactionType = 'Cancellation';

-- Validated: 3,836 invoices; -277,574 units; -£896,812.49.


-- 3.3 Final executive KPI summary
WITH metrics AS (
  SELECT
    SUM(CASE
      WHEN TransactionType IN ('Customer Sale', 'Cancellation')
      THEN LineValue ELSE 0 END) AS net_revenue,

    SUM(CASE
      WHEN TransactionType = 'Customer Sale'
      THEN LineValue ELSE 0 END) AS gross_sales,

    SUM(CASE
      WHEN TransactionType = 'Cancellation'
      THEN LineValue ELSE 0 END) AS cancellation_value,

    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
      THEN InvoiceNo END) AS total_orders,

    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
       AND CustomerID IS NOT NULL
      THEN CustomerID END) AS identifiable_customers,

    SUM(CASE
      WHEN TransactionType = 'Customer Sale'
      THEN Quantity ELSE 0 END) AS units_sold

  FROM `online-retail-analytics-511409.online_retail.processed_transactions`
)
SELECT
  ROUND(net_revenue, 2) AS net_revenue,
  ROUND(gross_sales, 2) AS gross_sales,
  ROUND(cancellation_value, 2) AS cancellation_value,
  total_orders,
  identifiable_customers,
  units_sold,
  ROUND(SAFE_DIVIDE(net_revenue, total_orders), 2)
    AS average_order_value
FROM metrics;

-- Expected:
-- Net Revenue        £9,758,809.99
-- Gross Sales       £10,655,622.48
-- Cancellation        -£896,812.49
-- Orders                    19,959
-- Customers                  4,338
-- Units                  5,588,375
-- AOV                       £488.94


-- =====================================================================
-- 4. REVENUE PERFORMANCE & TIME TRENDS
-- =====================================================================

-- 4.1 Monthly commercial performance
SELECT
  FORMAT_DATE('%Y-%m', TransactionDate) AS year_month,

  SUM(CASE
    WHEN TransactionType IN ('Customer Sale', 'Cancellation')
    THEN LineValue ELSE 0 END) AS net_revenue,

  COUNT(DISTINCT CASE
    WHEN TransactionType = 'Customer Sale'
    THEN InvoiceNo END) AS orders,

  COUNT(DISTINCT CASE
    WHEN TransactionType = 'Customer Sale'
     AND CustomerID IS NOT NULL
    THEN CustomerID END) AS customers,

  SUM(CASE
    WHEN TransactionType = 'Customer Sale'
    THEN Quantity ELSE 0 END) AS units_sold,

  SAFE_DIVIDE(
    SUM(CASE
      WHEN TransactionType IN ('Customer Sale', 'Cancellation')
      THEN LineValue ELSE 0 END),
    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
      THEN InvoiceNo END)
  ) AS average_order_value

FROM `online-retail-analytics-511409.online_retail.processed_transactions`
GROUP BY year_month
ORDER BY year_month;

-- November 2011 was the strongest complete month (~£1.46M).
-- December 2011 is partial through 9 December.


-- 4.2 Month-over-month Net Revenue
WITH monthly AS (
  SELECT
    DATE_TRUNC(TransactionDate, MONTH) AS month,
    SUM(CASE
      WHEN TransactionType IN ('Customer Sale', 'Cancellation')
      THEN LineValue ELSE 0 END) AS net_revenue
  FROM `online-retail-analytics-511409.online_retail.processed_transactions`
  GROUP BY month
),
comparison AS (
  SELECT
    month,
    net_revenue,
    LAG(net_revenue) OVER (ORDER BY month) AS previous_month_revenue
  FROM monthly
)
SELECT
  month,
  net_revenue,
  previous_month_revenue,
  ROUND(
    SAFE_DIVIDE(
      net_revenue - previous_month_revenue,
      previous_month_revenue
    ) * 100,
    2
  ) AS mom_revenue_change_pct
FROM comparison
ORDER BY month;


-- =====================================================================
-- 5. GEOGRAPHIC PERFORMANCE
-- =====================================================================

WITH country_metrics AS (
  SELECT
    Country,
    SUM(CASE
      WHEN TransactionType IN ('Customer Sale', 'Cancellation')
      THEN LineValue ELSE 0 END) AS net_revenue,

    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
      THEN InvoiceNo END) AS orders,

    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
       AND CustomerID IS NOT NULL
      THEN CustomerID END) AS customers

  FROM `online-retail-analytics-511409.online_retail.processed_transactions`
  GROUP BY Country
),
country_with_total AS (
  SELECT
    *,
    SUM(net_revenue) OVER () AS total_net_revenue
  FROM country_metrics
)
SELECT
  Country,
  net_revenue,
  ROUND(SAFE_DIVIDE(net_revenue, total_net_revenue) * 100, 2)
    AS revenue_share_pct,
  orders,
  customers,
  SAFE_DIVIDE(net_revenue, orders) AS average_order_value
FROM country_with_total
ORDER BY net_revenue DESC;

-- Key result: United Kingdom = £8,198,868.42 / 84.02% revenue share.
-- High-AOV smaller markets included Netherlands and Australia.


-- =====================================================================
-- 6. PRODUCT PERFORMANCE
-- =====================================================================

-- 6.1 Net merchandise ranking
-- Known non-merchandise/service codes excluded.
SELECT
  StockCode,
  ARRAY_AGG(
    Description IGNORE NULLS
    ORDER BY InvoiceDate DESC
    LIMIT 1
  )[SAFE_OFFSET(0)] AS product_description,

  SUM(CASE
    WHEN TransactionType IN ('Customer Sale', 'Cancellation')
    THEN LineValue ELSE 0 END) AS net_revenue,

  SUM(CASE
    WHEN TransactionType IN ('Customer Sale', 'Cancellation')
    THEN Quantity ELSE 0 END) AS net_units,

  COUNT(DISTINCT CASE
    WHEN TransactionType = 'Customer Sale'
    THEN InvoiceNo END) AS sales_orders

FROM `online-retail-analytics-511409.online_retail.processed_transactions`
WHERE UPPER(StockCode) NOT IN ('DOT', 'M', 'POST', 'AMAZONFEE', 'S')
GROUP BY StockCode
ORDER BY net_revenue DESC
LIMIT 20;

-- Validated leader:
-- REGENCY CAKESTAND 3 TIER
-- £164,762.19 Net Revenue; 13,022 net units; 1,988 sales orders.


-- 6.2 Validate PAPER CRAFT, LITTLE BIRDIE anomaly
SELECT
  InvoiceNo,
  InvoiceDate,
  StockCode,
  Description,
  Quantity,
  UnitPrice,
  CustomerID,
  Country,
  LineValue,
  TransactionType
FROM `online-retail-analytics-511409.online_retail.processed_transactions`
WHERE StockCode = '23843'
ORDER BY InvoiceDate;

-- Invoice 581483  = +80,995 units / +£168,469.60
-- Invoice C581484 = -80,995 units / -£168,469.60
-- Net contribution = £0.


-- =====================================================================
-- 7. CUSTOMER PERFORMANCE
-- =====================================================================

-- 7.1 Customer performance
WITH customer_metrics AS (
  SELECT
    CustomerID,

    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
      THEN InvoiceNo END) AS sales_orders,

    SUM(CASE
      WHEN TransactionType IN ('Customer Sale', 'Cancellation')
      THEN LineValue ELSE 0 END) AS net_revenue,

    SUM(CASE
      WHEN TransactionType = 'Customer Sale'
      THEN Quantity ELSE 0 END) AS units_sold

  FROM `online-retail-analytics-511409.online_retail.processed_transactions`
  WHERE CustomerID IS NOT NULL
  GROUP BY CustomerID
)
SELECT
  CustomerID,
  net_revenue,
  sales_orders,
  units_sold,
  SAFE_DIVIDE(net_revenue, sales_orders) AS average_order_value
FROM customer_metrics
WHERE sales_orders > 0
ORDER BY net_revenue DESC;


-- 7.2 Repeat-customer rate
WITH customer_orders AS (
  SELECT
    CustomerID,
    COUNT(DISTINCT InvoiceNo) AS sales_orders
  FROM `online-retail-analytics-511409.online_retail.processed_transactions`
  WHERE TransactionType = 'Customer Sale'
    AND CustomerID IS NOT NULL
  GROUP BY CustomerID
)
SELECT
  COUNT(*) AS identifiable_customers,
  COUNTIF(sales_orders = 1) AS one_time_customers,
  COUNTIF(sales_orders > 1) AS repeat_customers,
  ROUND(
    SAFE_DIVIDE(COUNTIF(sales_orders > 1), COUNT(*)) * 100,
    2
  ) AS repeat_customer_rate_pct
FROM customer_orders;

-- Validated:
-- 4,338 identifiable customers
-- 1,493 one-time
-- 2,845 repeat
-- 65.58% repeat-customer rate


-- 7.3 Customer revenue concentration by decile
WITH customer_revenue AS (
  SELECT
    CustomerID,
    SUM(CASE
      WHEN TransactionType IN ('Customer Sale', 'Cancellation')
      THEN LineValue ELSE 0 END) AS net_revenue
  FROM `online-retail-analytics-511409.online_retail.processed_transactions`
  WHERE CustomerID IS NOT NULL
  GROUP BY CustomerID
  HAVING COUNTIF(TransactionType = 'Customer Sale') > 0
),
ranked AS (
  SELECT
    CustomerID,
    net_revenue,
    NTILE(10) OVER (ORDER BY net_revenue DESC) AS revenue_decile
  FROM customer_revenue
),
deciles AS (
  SELECT
    revenue_decile,
    COUNT(*) AS customers,
    SUM(net_revenue) AS net_revenue
  FROM ranked
  GROUP BY revenue_decile
)
SELECT
  revenue_decile,
  customers,
  net_revenue,
  ROUND(
    SAFE_DIVIDE(net_revenue, SUM(net_revenue) OVER ()) * 100,
    2
  ) AS revenue_share_pct
FROM deciles
ORDER BY revenue_decile;

-- Validated:
-- Top decile = 438 customers / £4,984,121.39 / 60.05%.
-- Top 20% combined = 73.87%.


-- =====================================================================
-- 8. CUSTOMER SEGMENTATION
-- =====================================================================
-- Dataset-specific Q3 thresholds:
-- Net Revenue >= £1,625.97
-- Sales Orders >= 5

WITH customer_metrics AS (
  SELECT
    CustomerID,

    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
      THEN InvoiceNo END) AS sales_orders,

    SUM(CASE
      WHEN TransactionType IN ('Customer Sale', 'Cancellation')
      THEN LineValue ELSE 0 END) AS net_revenue

  FROM `online-retail-analytics-511409.online_retail.processed_transactions`
  WHERE CustomerID IS NOT NULL
  GROUP BY CustomerID
  HAVING COUNTIF(TransactionType = 'Customer Sale') > 0
),
segmented AS (
  SELECT
    *,
    CASE
      WHEN net_revenue >= 1625.97 AND sales_orders >= 5
        THEN 'High Value - High Frequency'
      WHEN net_revenue >= 1625.97 AND sales_orders < 5
        THEN 'High Value - Lower Frequency'
      WHEN net_revenue < 1625.97 AND sales_orders >= 5
        THEN 'Lower Value - High Frequency'
      ELSE 'Lower Value - Lower Frequency'
    END AS customer_segment
  FROM customer_metrics
),
segment_summary AS (
  SELECT
    customer_segment,
    COUNT(*) AS customers,
    SUM(net_revenue) AS net_revenue
  FROM segmented
  GROUP BY customer_segment
)
SELECT
  customer_segment,
  customers,
  net_revenue,
  ROUND(
    SAFE_DIVIDE(net_revenue, SUM(net_revenue) OVER ()) * 100,
    2
  ) AS revenue_share_pct
FROM segment_summary
ORDER BY net_revenue DESC;

-- Validated:
-- High Value - High Frequency:
--   833 customers / £5,806,006.01 / 69.86%
-- Lower Value - Lower Frequency:
--   2,976 customers / 17.99%
-- High Value - Lower Frequency:
--   248 customers / 8.36%
-- Lower Value - High Frequency:
--   281 customers / 3.79%


-- =====================================================================
-- 9. FINAL PORTFOLIO VALIDATION
-- =====================================================================

WITH final_check AS (
  SELECT
    SUM(CASE
      WHEN TransactionType IN ('Customer Sale', 'Cancellation')
      THEN LineValue ELSE 0 END) AS net_revenue,

    SUM(CASE
      WHEN TransactionType = 'Customer Sale'
      THEN LineValue ELSE 0 END) AS gross_sales,

    SUM(CASE
      WHEN TransactionType = 'Cancellation'
      THEN LineValue ELSE 0 END) AS cancellation_value,

    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
      THEN InvoiceNo END) AS total_orders,

    COUNT(DISTINCT CASE
      WHEN TransactionType = 'Customer Sale'
       AND CustomerID IS NOT NULL
      THEN CustomerID END) AS identifiable_customers,

    SUM(CASE
      WHEN TransactionType = 'Customer Sale'
      THEN Quantity ELSE 0 END) AS units_sold

  FROM `online-retail-analytics-511409.online_retail.processed_transactions`
)
SELECT
  ROUND(net_revenue, 2) AS net_revenue,
  ROUND(gross_sales, 2) AS gross_sales,
  ROUND(cancellation_value, 2) AS cancellation_value,
  total_orders,
  identifiable_customers,
  units_sold,
  ROUND(SAFE_DIVIDE(net_revenue, total_orders), 2)
    AS average_order_value
FROM final_check;

-- Expected final dashboard values:
-- Net Revenue         £9,758,809.99
-- Gross Sales        £10,655,622.48
-- Cancellation         -£896,812.49
-- Orders                     19,959
-- Customers                   4,338
-- Units                   5,588,375
-- AOV                        £488.94
--
-- =====================================================================
-- END OF SCRIPT
-- =====================================================================
