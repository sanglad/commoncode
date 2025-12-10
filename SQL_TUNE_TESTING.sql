WITH xla_tbl AS (
    SELECT xlate.source_id_int_1              trx_id,
           gcc.segment5                      receivable_account,
           glps.effective_period_num         effective_period_num,
           glps.start_date                   p_trx_from_date,
           glps.end_date                     p_trx_to_date,
           TO_CHAR(xlaah.accounting_date,'MM/DD/YYYY') gl_date
    FROM   xla_transaction_entities  xlate
           ,xla_ae_headers           xlaah
           ,xla_ae_lines             xlaal
           ,gl_period_statuses       glps
           ,gl_ledgers               gll
           ,gl_code_combinations     gcc
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
    AND    glps.effective_period_num BETWEEN 20260001 AND :p_to_period
    AND    gcc.segment5 = NVL(:p_account, gcc.segment5)
),
bounds AS (
    SELECT MIN(CASE WHEN effective_period_num = :p_from_period THEN p_trx_from_date END) AS from_date,
           MAX(CASE WHEN effective_period_num = :p_to_period   THEN p_trx_to_date   END) AS to_date
    FROM   xla_tbl
),
base_trx AS (
    SELECT DISTINCT
           xla.trx_id          AS customer_trx_id,
           xla.receivable_account,
           ract.trx_number     AS invoice_number
    FROM   xla_tbl xla,
           ra_customer_trx_all ract
    WHERE  ract.customer_trx_id = xla.trx_id
),
opening AS (
    SELECT bt.customer_trx_id,
           SUM(NVL(arps.amount_due_original,0))
         - SUM(NVL(arrp_prior.amount_applied,0))
         - SUM(NVL(arps.amount_credited * -1,0))
         + SUM(NVL(adj_prior.amount,0)) AS opening_balance
    FROM   base_trx bt
    JOIN   ar_payment_schedules_all arps
           ON arps.customer_trx_id = bt.customer_trx_id
    LEFT JOIN ar_receivable_applications_all arrp_prior
           ON arrp_prior.payment_schedule_id = arps.payment_schedule_id
          AND arrp_prior.display = 'Y'
          AND arrp_prior.apply_date < (SELECT from_date FROM bounds)
    LEFT JOIN ar_adjustments_all adj_prior
           ON adj_prior.customer_trx_id = bt.customer_trx_id
          AND adj_prior.apply_date < (SELECT from_date FROM bounds)
    WHERE  EXISTS (
              SELECT 1
              FROM   xla_tbl x
              WHERE  x.trx_id = bt.customer_trx_id
              AND    x.effective_period_num < :p_from_period
           )
    GROUP BY bt.customer_trx_id
),
additions AS (
    SELECT arps.customer_trx_id,
           SUM(NVL(arps.amount_due_original,0)) AS addition_amount
    FROM   ar_payment_schedules_all arps
    WHERE  arps.class IN ('INV','DM')
    AND    EXISTS (
              SELECT 1
              FROM   xla_tbl x
              WHERE  x.trx_id = arps.customer_trx_id
              AND    x.effective_period_num BETWEEN :p_from_period AND :p_to_period
           )
    AND    NOT EXISTS (
              SELECT 1
              FROM   ar_receivable_applications_all arrp
              WHERE  arrp.applied_payment_schedule_id = arps.payment_schedule_id
              AND    arrp.display = 'Y'
              AND    arrp.cash_receipt_id IS NOT NULL
              AND    arrp.apply_date BETWEEN (SELECT from_date FROM bounds)
                                       AND (SELECT to_date   FROM bounds)
           )
    GROUP BY arps.customer_trx_id
),
payments AS (
    SELECT arps.customer_trx_id,
           -1 * SUM(NVL(arrp.amount_applied,0)) AS payment_amount
    FROM   ar_payment_schedules_all arps
    JOIN   ar_receivable_applications_all arrp
           ON arrp.applied_payment_schedule_id = arps.payment_schedule_id
          AND arrp.display = 'Y'
          AND arrp.cash_receipt_id IS NOT NULL
          AND arrp.apply_date BETWEEN (SELECT from_date FROM bounds)
                                  AND (SELECT to_date   FROM bounds)
    WHERE  EXISTS (
              SELECT 1
              FROM   xla_tbl x
              WHERE  x.trx_id = arps.customer_trx_id
              AND    x.effective_period_num BETWEEN :p_from_period AND :p_to_period
           )
    GROUP BY arps.customer_trx_id
),
adjustments AS (
    SELECT adj_src.customer_trx_id,
           SUM(adj_src.amount) AS adjustment_amount
    FROM   (
              SELECT adj.customer_trx_id,
                     NVL(adj.amount,0) AS amount
              FROM   ar_adjustments_all adj
              WHERE  adj.apply_date BETWEEN (SELECT from_date FROM bounds)
                                       AND (SELECT to_date   FROM bounds)
              AND    adj.amount < 0
              AND    EXISTS (
                        SELECT 1
                        FROM   xla_tbl x
                        WHERE  x.trx_id = adj.customer_trx_id
                        AND    x.effective_period_num BETWEEN :p_from_period AND :p_to_period
                     )
              UNION ALL
              SELECT arrp.applied_customer_trx_id AS customer_trx_id,
                     -1 * NVL(arrp.amount_applied,0)               AS amount
              FROM   ar_receivable_applications_all arrp
              WHERE  arrp.display = 'Y'
              AND    arrp.application_type = 'CREDIT_MEMO'
              AND    arrp.apply_date BETWEEN (SELECT from_date FROM bounds)
                                       AND (SELECT to_date   FROM bounds)
              AND    EXISTS (
                        SELECT 1
                        FROM   xla_tbl x
                        WHERE  x.trx_id = arrp.applied_customer_trx_id
                        AND    x.effective_period_num BETWEEN :p_from_period AND :p_to_period
                     )
           ) adj_src
    GROUP BY adj_src.customer_trx_id
)
SELECT bt.customer_trx_id,
       bt.invoice_number,
       bt.receivable_account,
       NVL(op.opening_balance,0)            AS opening_balance,
       NVL(adds.addition_amount,0)          AS additions,
       NVL(pay.payment_amount,0)            AS payments,
       NVL(adj.adjustment_amount,0)         AS adjustments,
       NVL(op.opening_balance,0)
     + NVL(adds.addition_amount,0)
     + NVL(pay.payment_amount,0)
     + NVL(adj.adjustment_amount,0)         AS ending_balance
FROM   base_trx bt
LEFT JOIN opening     op   ON op.customer_trx_id   = bt.customer_trx_id
LEFT JOIN additions   adds ON adds.customer_trx_id = bt.customer_trx_id
LEFT JOIN payments    pay  ON pay.customer_trx_id  = bt.customer_trx_id
LEFT JOIN adjustments adj  ON adj.customer_trx_id  = bt.customer_trx_id
WHERE  bt.customer_trx_id IN (105010,120001,202015,105010)
ORDER BY bt.customer_trx_id;
