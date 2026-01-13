/* Bind parameters:
   :P_FROM_PERIOD  - from effective period number
   :P_TO_PERIOD    - to effective period number
   :p_account      - receivable account segment (optional)
*/

WITH ledger_periods AS (
  SELECT
    gl.ledger_id,
    gps.period_year,
    gps.effective_period_num,
    MIN(gps.effective_period_num)
      OVER (PARTITION BY gl.ledger_id, gps.period_year) AS starting_effective_period_num,
    gps.year_start_date,
    gps.start_date,
    gps.end_date
  FROM gl_period_statuses gps
  JOIN gl_ledgers gl ON gl.ledger_id = gps.ledger_id
  WHERE gps.closing_status IN ('C','O','W')
    AND gps.application_id = 222
    AND gl.name = 'AHA USD Primary Ledger'
),
bounds AS (
  SELECT
    ledger_id,
    period_year,
    MIN(starting_effective_period_num) AS starting_effective_period_num,
    MIN(year_start_date) AS inception_date,
    MIN(CASE WHEN effective_period_num = :P_FROM_PERIOD THEN start_date END) AS p_trx_from_date,
    MAX(CASE WHEN effective_period_num = :P_TO_PERIOD   THEN end_date   END) AS p_trx_to_date,
    :P_FROM_PERIOD AS p_from_period,
    :P_TO_PERIOD   AS p_to_period
  FROM ledger_periods
  WHERE effective_period_num BETWEEN :P_FROM_PERIOD AND :P_TO_PERIOD
  GROUP BY ledger_id, period_year
),

xla_full AS (
  SELECT
      xlate.source_id_int_1      AS trx_id,
      gcc.segment5              AS receivable_account,
      glps.effective_period_num AS effective_period_num,
      glps.start_date           AS p_trx_from_date,
      glps.end_date             AS p_trx_to_date,
      xlaah.accounting_date     AS gl_date_date
  FROM   xla_transaction_entities xlate,
         xla_ae_headers           xlaah,
         xla_ae_lines             xlaal,
         gl_period_statuses       glps,
         gl_ledgers               gll,
         gl_code_combinations     gcc
  WHERE  xlate.entity_code           = 'TRANSACTIONS'
  AND    xlate.entity_id             = xlaah.entity_id
  AND    xlaah.application_id        = 222
  AND    xlaah.ae_header_id          = xlaal.ae_header_id
  AND    xlaah.ledger_id             = xlaal.ledger_id
  AND    xlaal.accounting_class_code = 'RECEIVABLE'
  AND    xlaah.period_name           = glps.period_name
  AND    xlaah.ledger_id             = glps.ledger_id
  AND    glps.closing_status        IN ('C','O','W')
  AND    glps.application_id         = 222
  AND    glps.ledger_id              = gll.ledger_id
  AND    gll.name                    = 'AHA USD Primary Ledger'
  AND    xlaal.code_combination_id   = gcc.code_combination_id
  AND    xlaah.accounting_date BETWEEN glps.start_date AND glps.end_date
  AND    glps.effective_period_num BETWEEN (SELECT starting_effective_period_num FROM bounds)
                                      AND (SELECT p_to_period FROM bounds)
  AND    gcc.segment5 = NVL(:p_account, gcc.segment5)
),
xla_recv AS (
  SELECT
      trx_id,
      LISTAGG(DISTINCT receivable_account, ',')
        WITHIN GROUP (ORDER BY receivable_account) AS receivable_account,
      MAX(gl_date_date) AS gl_date_date
  FROM xla_full
  GROUP BY trx_id
),

Opening_net_bal AS (
  SELECT
      ps.customer_trx_id,
      ( SUM(NVL(ps.amount_due_original,0))
        - NVL((
            SELECT SUM(NVL(app.amount_applied,0))
            FROM ar_receivable_applications_all app
            CROSS JOIN bounds
            WHERE app.applied_customer_trx_id = ps.customer_trx_id
              AND app.status = 'APP'
              AND NVL(app.display,'Y') = 'Y'
              AND app.reversal_gl_date IS NULL
              AND app.application_type = 'CASH'
              AND TRUNC(app.gl_date) >= bounds.inception_date
              AND TRUNC(app.gl_date) <  bounds.p_trx_from_date
          ),0)
        - NVL((
            SELECT SUM(NVL(app.amount_applied,0))
            FROM ar_receivable_applications_all app
            CROSS JOIN bounds
            WHERE app.applied_customer_trx_id = ps.customer_trx_id
              AND app.status = 'APP'
              AND NVL(app.display,'Y') = 'Y'
              AND app.reversal_gl_date IS NULL
              AND app.application_type = 'CM'
              AND TRUNC(app.gl_date) >= bounds.inception_date
              AND TRUNC(app.gl_date) <  bounds.p_trx_from_date
          ),0)
      ) AS opening_amount
  FROM ar_payment_schedules_all ps
  CROSS JOIN bounds
  WHERE ps.class IN ('INV','DM')
    AND TRUNC(ps.gl_date) >= bounds.inception_date
    AND TRUNC(ps.gl_date) <  bounds.p_trx_from_date
  GROUP BY ps.customer_trx_id
),

Additions AS (
  SELECT
      ps.customer_trx_id,
      SUM(NVL(ps.amount_due_original,0)) AS addition_amount
  FROM ar_payment_schedules_all ps
  CROSS JOIN bounds
  WHERE ps.class IN ('INV','DM')
    AND TRUNC(ps.gl_date) BETWEEN bounds.p_trx_from_date AND bounds.p_trx_to_date
  GROUP BY ps.customer_trx_id
),

Payments AS (
  SELECT
      app.applied_customer_trx_id AS customer_trx_id,
      SUM(NVL(app.amount_applied,0)) AS payment_amount
  FROM ar_receivable_applications_all app
  CROSS JOIN bounds
  WHERE app.status = 'APP'
    AND NVL(app.display,'Y') = 'Y'
    AND app.reversal_gl_date IS NULL
    AND app.application_type = 'CASH'
    AND app.applied_customer_trx_id IS NOT NULL
    AND TRUNC(app.gl_date) BETWEEN bounds.p_trx_from_date AND bounds.p_trx_to_date
  GROUP BY app.applied_customer_trx_id
),

/* CM Adjustments */
Adjustments AS (
  SELECT
      app.applied_customer_trx_id AS customer_trx_id,
      -SUM(NVL(app.amount_applied,0)) AS adjustment_amount
  FROM ar_receivable_applications_all app
  CROSS JOIN bounds
  WHERE app.status = 'APP'
    AND NVL(app.display,'Y') = 'Y'
    AND app.reversal_gl_date IS NULL
    AND app.application_type = 'CM'
    AND app.applied_customer_trx_id IS NOT NULL
    AND TRUNC(app.gl_date) BETWEEN bounds.p_trx_from_date AND bounds.p_trx_to_date
  GROUP BY app.applied_customer_trx_id
),

/* Manual adjustments  - opening net */
AR_ADJ_OPENING AS (
  SELECT
      ps.customer_trx_id,
      SUM(NVL(adj.amount,0)) AS adj_opening_amount
  FROM ar_adjustments_all adj
  JOIN ar_payment_schedules_all ps
    ON ps.payment_schedule_id = adj.payment_schedule_id
  CROSS JOIN bounds b
  WHERE ps.class IN ('INV','DM')
    AND adj.status = 'A'
    AND NVL(adj.postable,'N') = 'Y'
    AND TRUNC(adj.gl_date) >= b.inception_date
    AND TRUNC(adj.gl_date) <  b.p_trx_from_date
  GROUP BY ps.customer_trx_id
),

/* Manual adjustments - in period */
AR_ADJ_PERIOD AS (
  SELECT
      ps.customer_trx_id,
      SUM(NVL(adj.amount,0)) AS adj_period_amount
  FROM ar_adjustments_all adj
  JOIN ar_payment_schedules_all ps
    ON ps.payment_schedule_id = adj.payment_schedule_id
  CROSS JOIN bounds b
  WHERE ps.class IN ('INV','DM')
    AND adj.status = 'A'
    AND NVL(adj.postable,'N') = 'Y'
    AND TRUNC(adj.gl_date) BETWEEN b.p_trx_from_date AND b.p_trx_to_date
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
      arps1.customer_trx_id,
      arps1.amount_due_original,
      arps1.due_date,
      CASE
        WHEN arps1.actual_date_closed >= (SELECT p_trx_to_date FROM bounds)
          OR arps1.actual_date_closed BETWEEN (SELECT p_trx_from_date FROM bounds) AND (SELECT p_trx_to_date FROM bounds)
        THEN 'OP'
        ELSE pmt.status
      END AS inv_status
  FROM arps1
  JOIN ra_customer_trx_all ract
    ON ract.customer_trx_id = arps1.customer_trx_id
  JOIN ar_payment_schedules_all pmt
    ON pmt.customer_trx_id = arps1.customer_trx_id
   AND pmt.due_date        = arps1.due_date
)

SELECT
    ract.customer_trx_id                    AS customer_trx_id,
    ract.trx_number                         AS invoice_number,
    xrecv.receivable_account                AS receivable_account,
    hzca.account_number                      AS customer_num,
    hzp.party_name                           AS customer_name,
    hzca.customer_type                       AS account_type,
    TO_CHAR(ract.trx_date,'MM/DD/YYYY')      AS invoice_date,
    TO_CHAR(arps.due_date,'MM/DD/YYYY')      AS due_date,
    TO_CHAR(xrecv.gl_date_date,'MM/DD/YYYY') AS gl_date,

    /* opening now includes AR_ADJUSTMENTS_ALL (opening) */
    ( NVL(Opening_net_bal.opening_amount,0)
    + NVL(ao.adj_opening_amount,0)
    ) AS opening_balance,

    NVL(Additions.addition_amount,0)              AS addition,
    NVL(-1 * Payments.payment_amount,0)           AS payment,

    /* adjustment now includes CM apps + AR_ADJUSTMENTS_ALL (period) */
    ( NVL(Adjustments.adjustment_amount,0)
    + NVL(ap.adj_period_amount,0)
    ) AS adjustment,

    ( NVL(Opening_net_bal.opening_amount,0) + NVL(ao.adj_opening_amount,0)
    + NVL(Additions.addition_amount,0)
    + NVL(-1 * Payments.payment_amount,0)
    + NVL(Adjustments.adjustment_amount,0) + NVL(ap.adj_period_amount,0)
    ) AS ending_balance

FROM ra_customer_trx_all ract
JOIN xla_recv xrecv
  ON xrecv.trx_id = ract.customer_trx_id
LEFT JOIN arps
  ON arps.customer_trx_id = ract.customer_trx_id
LEFT JOIN Opening_net_bal
  ON Opening_net_bal.customer_trx_id = ract.customer_trx_id
LEFT JOIN Additions
  ON Additions.customer_trx_id = ract.customer_trx_id
LEFT JOIN Payments
  ON Payments.customer_trx_id = ract.customer_trx_id
LEFT JOIN Adjustments
  ON Adjustments.customer_trx_id = ract.customer_trx_id
LEFT JOIN AR_ADJ_OPENING ao
  ON ao.customer_trx_id = ract.customer_trx_id
LEFT JOIN AR_ADJ_PERIOD ap
  ON ap.customer_trx_id = ract.customer_trx_id
LEFT JOIN hz_cust_accounts hzca
  ON hzca.cust_account_id = ract.bill_to_customer_id
LEFT JOIN hz_parties hzp
  ON hzp.party_id = hzca.party_id

WHERE 1=1
 -- AND ract.customer_trx_id IN (140023,140025,140028,109043,112014)
  AND (
      NVL(Opening_net_bal.opening_amount,0) <> 0
   OR NVL(ao.adj_opening_amount,0)          <> 0
   OR NVL(Additions.addition_amount,0)      <> 0
   OR NVL(Payments.payment_amount,0)        <> 0
   OR NVL(Adjustments.adjustment_amount,0)  <> 0
   OR NVL(ap.adj_period_amount,0)           <> 0
  )
ORDER BY ract.customer_trx_id;
