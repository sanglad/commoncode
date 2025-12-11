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
           xla.trx_id                                AS customer_trx_id,
           NVL(ract.previous_customer_trx_id, xla.trx_id) AS group_trx_id,
           xla.receivable_account,
           ract.trx_number                           AS invoice_number,
           ract.trx_class                            AS trx_class,
           ract.previous_customer_trx_id              AS parent_customer_trx_id,
           xla.effective_period_num                   AS trx_period_num
    FROM   xla_tbl xla
    JOIN   ra_customer_trx_all ract
           ON ract.customer_trx_id = xla.trx_id
),
grouped_trx AS (
    SELECT bt.group_trx_id,
           COALESCE(
               MAX(CASE
                     WHEN bt.customer_trx_id = bt.group_trx_id
                          OR bt.parent_customer_trx_id IS NULL
                     THEN bt.invoice_number
                   END),
               MAX(bt.invoice_number)
           ) AS invoice_number,
           MAX(bt.receivable_account) AS receivable_account
    FROM   base_trx bt
    GROUP BY bt.group_trx_id
),
opening AS (
    SELECT bt.group_trx_id,
           SUM(NVL(arps.amount_due_original,0))
         - SUM(NVL(arrp_prior.amount_applied,0))
         - SUM(NVL(arps.amount_credited * -1,0))
         + SUM(NVL(adj_prior.amount,0))      AS opening_balance
    FROM   base_trx bt
    JOIN   ar_payment_schedules_all arps
           ON arps.customer_trx_id = bt.customer_trx_id
    CROSS JOIN bounds b
    LEFT JOIN ar_receivable_applications_all arrp_prior
           ON arrp_prior.payment_schedule_id = arps.payment_schedule_id
          AND arrp_prior.display = 'Y'
          AND arrp_prior.apply_date < b.from_date
    LEFT JOIN ar_adjustments_all adj_prior
           ON adj_prior.customer_trx_id = bt.customer_trx_id
          AND adj_prior.apply_date < b.from_date
    WHERE  bt.trx_class IN ('INV','DM')
    AND    arps.class   IN ('INV','DM')
    AND    bt.trx_period_num < :p_from_period
    GROUP BY bt.group_trx_id
),
additions AS (
    SELECT bt.group_trx_id,
           SUM(NVL(arps.amount_due_original,0)) AS addition_amount
    FROM   base_trx bt
    JOIN   ar_payment_schedules_all arps
           ON arps.customer_trx_id = bt.customer_trx_id
    WHERE  bt.trx_class IN ('INV','DM')
    AND    arps.class   IN ('INV','DM')
    AND    bt.trx_period_num BETWEEN :p_from_period AND :p_to_period
    GROUP BY bt.group_trx_id
),
payments AS (
    SELECT pay_src.group_trx_id,
           SUM(pay_src.amount) AS payment_amount
    FROM   (
              SELECT bt.group_trx_id,
                     -1 * NVL(arrp.amount_applied,0) AS amount
              FROM   base_trx bt
              JOIN   ar_payment_schedules_all arps
                     ON arps.customer_trx_id = bt.customer_trx_id
                    AND arps.class IN ('INV','DM')
              JOIN   ar_receivable_applications_all arrp
                     ON arrp.applied_payment_schedule_id = arps.payment_schedule_id
                    AND arrp.display = 'Y'
              CROSS JOIN bounds b
              WHERE  bt.trx_class IN ('INV','DM')
              AND    bt.trx_period_num BETWEEN :p_from_period AND :p_to_period
              AND    arrp.cash_receipt_id IS NOT NULL
              AND    NVL(arrp.amount_applied,0) <> 0
              AND    arrp.apply_date BETWEEN b.from_date AND b.to_date
              UNION ALL
              SELECT tgt.group_trx_id,
                     -1 * NVL(arrp.amount_applied,0) AS amount
              FROM   ar_receivable_applications_all arrp
              JOIN   base_trx cm
                     ON cm.customer_trx_id = arrp.customer_trx_id
              JOIN   base_trx tgt
                     ON tgt.customer_trx_id = arrp.applied_customer_trx_id
              CROSS JOIN bounds b
              WHERE  arrp.display = 'Y'
              AND    arrp.application_type = 'CREDIT_MEMO'
              AND    NVL(arrp.amount_applied,0) <> 0
              AND    arrp.apply_date BETWEEN b.from_date AND b.to_date
              AND    cm.trx_class = 'CM'
              AND    cm.trx_period_num BETWEEN :p_from_period AND :p_to_period
              AND    tgt.trx_class IN ('INV','DM')
              AND    tgt.trx_period_num BETWEEN :p_from_period AND :p_to_period
           ) pay_src
    GROUP BY pay_src.group_trx_id
),
adjustments AS (
    SELECT adj_src.group_trx_id,
           SUM(adj_src.amount) AS adjustment_amount
    FROM   (
              SELECT bt.group_trx_id,
                     NVL(adj.amount,0) AS amount
              FROM   base_trx bt
              JOIN   ar_adjustments_all adj
                     ON adj.customer_trx_id = bt.customer_trx_id
              CROSS JOIN bounds b
              WHERE  adj.apply_date BETWEEN b.from_date AND b.to_date
              AND    NVL(adj.amount,0) <> 0
              AND    bt.trx_period_num BETWEEN :p_from_period AND :p_to_period
              UNION ALL
              SELECT bt.group_trx_id,
                     NVL(arps.amount_due_original,0) AS amount
              FROM   base_trx bt
              JOIN   ar_payment_schedules_all arps
                     ON arps.customer_trx_id = bt.customer_trx_id
              WHERE  arps.amount_due_original < 0
              AND    NVL(arps.amount_due_original,0) <> 0
              AND    bt.trx_period_num BETWEEN :p_from_period AND :p_to_period
           ) adj_src
    GROUP BY adj_src.group_trx_id
)
SELECT grp.group_trx_id                     AS customer_trx_id,
       grp.invoice_number,
       grp.receivable_account,
       NVL(op.opening_balance,0)            AS opening_balance,
       NVL(adds.addition_amount,0)          AS additions,
       NVL(pay.payment_amount,0)            AS payments,
       NVL(adj.adjustment_amount,0)         AS adjustments,
       NVL(op.opening_balance,0)
     + NVL(adds.addition_amount,0)
     + NVL(pay.payment_amount,0)
     + NVL(adj.adjustment_amount,0)         AS ending_balance
FROM   grouped_trx grp
LEFT JOIN opening     op   ON op.group_trx_id   = grp.group_trx_id
LEFT JOIN additions   adds ON adds.group_trx_id = grp.group_trx_id
LEFT JOIN payments    pay  ON pay.group_trx_id  = grp.group_trx_id
LEFT JOIN adjustments adj  ON adj.group_trx_id  = grp.group_trx_id
WHERE  grp.group_trx_id IN (105010,120001,202015,105010)
   OR EXISTS (
          SELECT 1
          FROM   base_trx bt_filter
          WHERE  bt_filter.group_trx_id = grp.group_trx_id
          AND    bt_filter.customer_trx_id IN (105010,120001,202015,105010)
       )
ORDER BY grp.group_trx_id;
