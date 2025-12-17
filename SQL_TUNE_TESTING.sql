/*
Customer transaction balance calculation (AR + SLA)

Key changes vs. the “correlated subquery” style:
- Aggregate AR applications (CASH / CM) once, split into opening vs in-period using bounds dates
- Aggregate AR manual adjustments once, split into opening vs in-period using bounds dates
- Avoid TRUNC() on potentially indexed date columns by using >= / < / <= boundaries

Binds:
  :p_from_period  -> GL effective_period_num (SLA/GL effective period number)
  :p_account      -> receivable account segment5 (optional)
*/

WITH ledger_periods AS (
  SELECT
    gl.ledger_id,
    gps.period_year,
    gps.effective_period_num,
    MIN(gps.effective_period_num) OVER (PARTITION BY gl.ledger_id, gps.period_year) AS starting_effective_period_num,
    gps.year_start_date,
    gps.start_date,
    gps.end_date
  FROM gl_period_statuses gps
  JOIN gl_ledgers gl
    ON gl.ledger_id = gps.ledger_id
  WHERE gps.closing_status IN ('C','O','W')
    AND gps.application_id = 222
    AND gl.name = 'AHA USD Primary Ledger'
),
bounds AS (
  SELECT
    ledger_id,
    period_year,
    effective_period_num,
    starting_effective_period_num,
    MIN(year_start_date) AS inception_date,
    MIN(start_date)      AS p_trx_from_date,
    MAX(end_date)        AS p_trx_to_date
  FROM ledger_periods
  WHERE effective_period_num = :p_from_period
  GROUP BY ledger_id, period_year, effective_period_num, starting_effective_period_num
),

xla_full AS (
  SELECT
    xlate.source_id_int_1  AS trx_id,
    gcc.segment5           AS receivable_account,
    glps.effective_period_num,
    glps.start_date        AS p_trx_from_date,
    glps.end_date          AS p_trx_to_date,
    xlaah.accounting_date  AS gl_date_date
  FROM xla_transaction_entities xlate
  JOIN xla_ae_headers xlaah
    ON xlaah.entity_id = xlate.entity_id
   AND xlaah.application_id = 222
  JOIN xla_ae_lines xlaal
    ON xlaal.ae_header_id = xlaah.ae_header_id
   AND xlaal.ledger_id    = xlaah.ledger_id
   AND xlaal.accounting_class_code = 'RECEIVABLE'
  JOIN gl_period_statuses glps
    ON glps.period_name = xlaah.period_name
   AND glps.ledger_id   = xlaah.ledger_id
   AND glps.application_id = 222
   AND glps.closing_status IN ('C','O','W')
  JOIN gl_ledgers gll
    ON gll.ledger_id = glps.ledger_id
   AND gll.name      = 'AHA USD Primary Ledger'
  JOIN gl_code_combinations gcc
    ON gcc.code_combination_id = xlaal.code_combination_id
  WHERE xlate.entity_code = 'TRANSACTIONS'
    AND xlaah.accounting_date BETWEEN glps.start_date AND glps.end_date
    AND glps.effective_period_num BETWEEN (SELECT starting_effective_period_num FROM bounds)
                                     AND (SELECT effective_period_num          FROM bounds)
    AND gcc.segment5 = NVL(:p_account, gcc.segment5)
),
xla_recv AS (
  SELECT
    trx_id,
    LISTAGG(DISTINCT receivable_account, ',') WITHIN GROUP (ORDER BY receivable_account) AS receivable_account,
    MAX(gl_date_date) AS gl_date_date
  FROM xla_full
  GROUP BY trx_id
),

/* Invoice side (amounts due) split into opening vs in-period */
ar_inv AS (
  SELECT
    ps.customer_trx_id,
    SUM(CASE
          WHEN ps.class IN ('INV','DM')
           AND ps.gl_date >= b.inception_date
           AND ps.gl_date <  b.p_trx_from_date
          THEN NVL(ps.amount_due_original,0)
          ELSE 0
        END) AS inv_opening_amount,
    SUM(CASE
          WHEN ps.class IN ('INV','DM')
           AND ps.gl_date >= b.p_trx_from_date
           AND ps.gl_date <= b.p_trx_to_date
          THEN NVL(ps.amount_due_original,0)
          ELSE 0
        END) AS inv_period_amount
  FROM ar_payment_schedules_all ps
  CROSS JOIN bounds b
  WHERE ps.class IN ('INV','DM')
    AND ps.gl_date >= b.inception_date
    AND ps.gl_date <= b.p_trx_to_date
  GROUP BY ps.customer_trx_id
),

/* Applications (CASH / CM) split into opening vs in-period */
ar_apps AS (
  SELECT
    app.applied_customer_trx_id AS customer_trx_id,
    SUM(CASE
          WHEN app.application_type = 'CASH'
           AND app.apply_date >= b.inception_date
           AND app.apply_date <  b.p_trx_from_date
          THEN NVL(app.amount_applied,0)
          ELSE 0
        END) AS cash_opening_amount,
    SUM(CASE
          WHEN app.application_type = 'CM'
           AND app.apply_date >= b.inception_date
           AND app.apply_date <  b.p_trx_from_date
          THEN NVL(app.amount_applied,0)
          ELSE 0
        END) AS cm_opening_amount,
    SUM(CASE
          WHEN app.application_type = 'CASH'
           AND app.apply_date >= b.p_trx_from_date
           AND app.apply_date <= b.p_trx_to_date
          THEN NVL(app.amount_applied,0)
          ELSE 0
        END) AS cash_period_amount,
    SUM(CASE
          WHEN app.application_type = 'CM'
           AND app.apply_date >= b.p_trx_from_date
           AND app.apply_date <= b.p_trx_to_date
          THEN NVL(app.amount_applied,0)
          ELSE 0
        END) AS cm_period_amount
  FROM ar_receivable_applications_all app
  CROSS JOIN bounds b
  WHERE app.status = 'APP'
    AND NVL(app.display,'Y') = 'Y'
    AND app.reversal_gl_date IS NULL
    AND app.application_type IN ('CASH','CM')
    AND app.applied_customer_trx_id IS NOT NULL
    AND app.apply_date >= b.inception_date
    AND app.apply_date <= b.p_trx_to_date
  GROUP BY app.applied_customer_trx_id
),

/* Manual adjustments (AR_ADJUSTMENTS_ALL) split into opening vs in-period */
ar_adj AS (
  SELECT
    ps.customer_trx_id,
    SUM(CASE
          WHEN adj.gl_date >= b.inception_date
           AND adj.gl_date <  b.p_trx_from_date
          THEN NVL(adj.amount,0)
          ELSE 0
        END) AS adj_opening_amount,
    SUM(CASE
          WHEN adj.gl_date >= b.p_trx_from_date
           AND adj.gl_date <= b.p_trx_to_date
          THEN NVL(adj.amount,0)
          ELSE 0
        END) AS adj_period_amount
  FROM ar_adjustments_all adj
  JOIN ar_payment_schedules_all ps
    ON ps.payment_schedule_id = adj.payment_schedule_id
  CROSS JOIN bounds b
  WHERE ps.class IN ('INV','DM')
    AND adj.status = 'A'
    AND NVL(adj.posted_flag,'N') = 'Y'
    AND adj.gl_date >= b.inception_date
    AND adj.gl_date <= b.p_trx_to_date
  GROUP BY ps.customer_trx_id
),

arps1 AS (
  SELECT
    customer_trx_id,
    SUM(amount_due_original) AS amount_due_original,
    MAX(due_date)            AS due_date,
    MAX(actual_date_closed)  AS actual_date_closed
  FROM ar_payment_schedules_all
  GROUP BY customer_trx_id
),
arps AS (
  SELECT
    a.customer_trx_id,
    a.amount_due_original,
    a.due_date,
    CASE
      WHEN a.actual_date_closed >= b.p_trx_to_date
        OR a.actual_date_closed BETWEEN b.p_trx_from_date AND b.p_trx_to_date
      THEN 'OP'
      ELSE pmt.status
    END AS inv_status
  FROM arps1 a
  CROSS JOIN bounds b
  JOIN ra_customer_trx_all ract
    ON ract.customer_trx_id = a.customer_trx_id
  JOIN ar_payment_schedules_all pmt
    ON pmt.customer_trx_id = a.customer_trx_id
   AND pmt.due_date        = a.due_date
)

SELECT
  ract.customer_trx_id                     AS customer_trx_id,
  ract.trx_number                          AS invoice_number,
  xrecv.receivable_account                 AS receivable_account,
  hzca.account_number                      AS customer_num,
  hzp.party_name                           AS customer_name,
  hzca.customer_type                       AS account_type,
  TO_CHAR(ract.trx_date,'MM/DD/YYYY')      AS invoice_date,
  TO_CHAR(arps.due_date,'MM/DD/YYYY')      AS due_date,
  TO_CHAR(xrecv.gl_date_date,'MM/DD/YYYY') AS gl_date,

  /* opening = invoices - (cash + cm) + manual adjustments */
  ( NVL(inv.inv_opening_amount,0)
  - NVL(apps.cash_opening_amount,0)
  - NVL(apps.cm_opening_amount,0)
  + NVL(adj.adj_opening_amount,0)
  ) AS opening_balance,

  NVL(inv.inv_period_amount,0)                 AS addition,
  NVL(-1 * apps.cash_period_amount,0)          AS payment,
  ( NVL(-1 * apps.cm_period_amount,0)
  + NVL(adj.adj_period_amount,0)
  ) AS adjustment,

  /* ending = opening + in-period movement */
  ( ( NVL(inv.inv_opening_amount,0)
    - NVL(apps.cash_opening_amount,0)
    - NVL(apps.cm_opening_amount,0)
    + NVL(adj.adj_opening_amount,0)
    )
  + NVL(inv.inv_period_amount,0)
  + NVL(-1 * apps.cash_period_amount,0)
  + NVL(-1 * apps.cm_period_amount,0)
  + NVL(adj.adj_period_amount,0)
  ) AS ending_balance

FROM ra_customer_trx_all ract
JOIN xla_recv xrecv
  ON xrecv.trx_id = ract.customer_trx_id
LEFT JOIN arps
  ON arps.customer_trx_id = ract.customer_trx_id
LEFT JOIN ar_inv inv
  ON inv.customer_trx_id = ract.customer_trx_id
LEFT JOIN ar_apps apps
  ON apps.customer_trx_id = ract.customer_trx_id
LEFT JOIN ar_adj adj
  ON adj.customer_trx_id = ract.customer_trx_id
LEFT JOIN hz_cust_accounts hzca
  ON hzca.cust_account_id = ract.bill_to_customer_id
LEFT JOIN hz_parties hzp
  ON hzp.party_id = hzca.party_id

WHERE 1=1
  AND ract.customer_trx_id IN (140023,140025,140028,109043,112014)
  AND (
       NVL(inv.inv_opening_amount,0)       <> 0
    OR NVL(apps.cash_opening_amount,0)     <> 0
    OR NVL(apps.cm_opening_amount,0)       <> 0
    OR NVL(adj.adj_opening_amount,0)       <> 0
    OR NVL(inv.inv_period_amount,0)        <> 0
    OR NVL(apps.cash_period_amount,0)      <> 0
    OR NVL(apps.cm_period_amount,0)        <> 0
    OR NVL(adj.adj_period_amount,0)        <> 0
  )

ORDER BY ract.customer_trx_id;
