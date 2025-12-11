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
           ract.previous_customer_trx_id              AS parent_customer_trx_id
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
           SUM(NVL(arps.amount_due_original,0)) AS opening_balance
    FROM   base_trx bt
    JOIN   ar_payment_schedules_all arps
           ON arps.customer_trx_id = bt.customer_trx_id
    WHERE  bt.trx_class IN ('INV','DM')
    AND    arps.class   IN ('INV','DM')
    AND    EXISTS (
              SELECT 1
              FROM   xla_tbl x
              WHERE  x.trx_id = bt.customer_trx_id
              AND    x.effective_period_num < :p_from_period
           )
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
    AND    EXISTS (
              SELECT 1
              FROM   xla_tbl x
              WHERE  x.trx_id = bt.customer_trx_id
              AND    x.effective_period_num BETWEEN :p_from_period AND :p_to_period
           )
    GROUP BY bt.group_trx_id
),
payments AS (
    SELECT bt.group_trx_id,
           -1 * SUM(NVL(arrp.amount_applied,0)) AS payment_amount
    FROM   base_trx bt
    JOIN   ar_payment_schedules_all arps
           ON arps.customer_trx_id = bt.customer_trx_id
    JOIN   ar_receivable_applications_all arrp
           ON arrp.applied_payment_schedule_id = arps.payment_schedule_id
          AND arrp.display = 'Y'
          AND arrp.apply_date BETWEEN (SELECT from_date FROM bounds)
                                  AND (SELECT to_date   FROM bounds)
    WHERE  bt.trx_class IN ('INV','DM')
    AND    arps.class   IN ('INV','DM')
    AND    EXISTS (
              SELECT 1
              FROM   xla_tbl x
              WHERE  x.trx_id = bt.customer_trx_id
              AND    x.effective_period_num BETWEEN :p_from_period AND :p_to_period
           )
    GROUP BY bt.group_trx_id
),
adjustments AS (
    SELECT NVL(src.group_trx_id, tgt.group_trx_id) AS group_trx_id,
           -1 * SUM(NVL(arrp.amount_applied,0))    AS adjustment_amount
    FROM   ar_receivable_applications_all arrp
    JOIN   base_trx src
           ON src.customer_trx_id = arrp.customer_trx_id
    LEFT JOIN ar_payment_schedules_all src_arps
           ON src_arps.customer_trx_id = src.customer_trx_id
    LEFT JOIN base_trx tgt
           ON tgt.customer_trx_id = arrp.applied_customer_trx_id
    WHERE  arrp.display = 'Y'
    AND    arrp.customer_trx_id IS NOT NULL
    AND    NVL(arrp.amount_applied,0) <> 0
    AND    arrp.apply_date BETWEEN (SELECT from_date FROM bounds)
                              AND (SELECT to_date   FROM bounds)
    AND    EXISTS (
              SELECT 1
              FROM   xla_tbl x
              WHERE  x.trx_id = src.customer_trx_id
              AND    x.effective_period_num BETWEEN :p_from_period AND :p_to_period
           )
    AND    (
              src.trx_class = 'CM'
           OR NVL(src_arps.amount_due_original,0) < 0
           )
    GROUP BY NVL(src.group_trx_id, tgt.group_trx_id)
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
