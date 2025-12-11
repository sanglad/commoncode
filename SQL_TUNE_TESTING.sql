/*
Parameters:
:p_ledger_id -- GL ledger
:p_from_period_name -- From GL period (inclusive)
:p_to_period_name -- To GL period (inclusive)
*/

WITH period_bounds AS (
    SELECT MIN(CASE WHEN glps.effective_period_num = :p_from_period THEN glps.start_date END) AS from_start_date,
           MAX(CASE WHEN glps.effective_period_num = :p_to_period   THEN glps.end_date   END) AS to_end_date,
           MIN(CASE WHEN glps.effective_period_num = :p_from_period THEN glps.start_date END) - 1 AS opening_as_of_date
    FROM   xla_transaction_entities xlate
    JOIN   xla_ae_headers           xlaah ON xlate.entity_id    = xlaah.entity_id
    JOIN   xla_ae_lines             xlaal ON xlaah.ae_header_id = xlaal.ae_header_id
                                         AND xlaah.ledger_id    = xlaal.ledger_id
    JOIN   gl_period_statuses       glps  ON xlaah.period_name  = glps.period_name
                                         AND xlaah.ledger_id    = glps.ledger_id
    JOIN   gl_ledgers               gll   ON gll.ledger_id      = glps.ledger_id
    JOIN   gl_code_combinations     gcc   ON gcc.code_combination_id = xlaal.code_combination_id
    WHERE  xlate.entity_code             = 'TRANSACTIONS'
    AND    xlaah.application_id          = 222
    AND    xlaal.accounting_class_code   = 'RECEIVABLE'
    AND    glps.closing_status          IN ('C','O','W')
    AND    glps.application_id           = 222
    AND    gll.ledger_id                 = :p_ledger_id
    AND    glps.effective_period_num BETWEEN :p_from_period AND :p_to_period
    AND    xlaah.accounting_date BETWEEN glps.start_date AND glps.end_date
    AND    gcc.segment5                  = NVL(:p_account, gcc.segment5)
),

base_trx AS (
    SELECT rct.customer_trx_id,
           rct.trx_number,
           rct.trx_date,
           rct.bill_to_customer_id,
           rct.trx_type,
           ps.payment_schedule_id,
           ps.amount_due_original,
           ps.invoice_currency_code
    FROM   ra_customer_trx_all   rct,
           ar_payment_schedules_all ps
    WHERE  ps.customer_trx_id = rct.customer_trx_id
    AND    rct.org_id         = ps.org_id
    AND    rct.complete_flag  = 'Y'
),

inv_acct AS (
    SELECT b.customer_trx_id,
           gcc.segment5,
           SUM(CASE
                 WHEN xae.accounting_date <= pb.opening_as_of_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS opening_invoiced,
           SUM(CASE
                 WHEN xae.accounting_date BETWEEN pb.from_start_date AND pb.to_end_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS period_invoiced
    FROM   base_trx b
    JOIN   xla_distribution_links xdl
           ON xdl.source_distribution_type = 'AR_PAYMENT_SCHEDULES'
          AND xdl.source_distribution_id_num_1 = b.payment_schedule_id
    JOIN   xla_ae_lines xala
           ON xala.ae_header_id = xdl.ae_header_id
          AND xala.ae_line_num  = xdl.ae_line_num
    JOIN   xla_ae_headers xae
           ON xae.ae_header_id = xala.ae_header_id
    JOIN   gl_code_combinations gcc
           ON gcc.code_combination_id = xala.code_combination_id
    CROSS JOIN period_bounds pb
    WHERE  xae.ledger_id            = :p_ledger_id
    AND    xala.accounting_class_code = 'REC'
    GROUP BY b.customer_trx_id,
             gcc.segment5
),

cash_receipts AS (
    SELECT b.customer_trx_id,
           gcc.segment5,
           SUM(CASE
                 WHEN xae.accounting_date <= pb.opening_as_of_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS opening_receipts,
           SUM(CASE
                 WHEN xae.accounting_date BETWEEN pb.from_start_date AND pb.to_end_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS period_receipts
    FROM   base_trx b
    JOIN   ar_receivable_applications_all app
           ON app.payment_schedule_id = b.payment_schedule_id
    JOIN   ar_cash_receipts_all cr
           ON cr.cash_receipt_id = app.cash_receipt_id
    JOIN   xla_distribution_links xdl
           ON xdl.source_distribution_type = 'AR_RECEIVABLE_APPLICATIONS'
          AND xdl.source_distribution_id_num_1 = app.receivable_application_id
    JOIN   xla_ae_lines xala
           ON xala.ae_header_id = xdl.ae_header_id
          AND xala.ae_line_num  = xdl.ae_line_num
    JOIN   xla_ae_headers xae
           ON xae.ae_header_id = xala.ae_header_id
    JOIN   gl_code_combinations gcc
           ON gcc.code_combination_id = xala.code_combination_id
    CROSS JOIN period_bounds pb
    WHERE  xae.ledger_id            = :p_ledger_id
    AND    xala.accounting_class_code = 'REC'
    AND    app.application_type      = 'CASH'
    GROUP BY b.customer_trx_id,
             gcc.segment5
),

credit_memos AS (
    SELECT b.customer_trx_id,
           gcc.segment5,
           SUM(CASE
                 WHEN xae.accounting_date <= pb.opening_as_of_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS opening_credits,
           SUM(CASE
                 WHEN xae.accounting_date BETWEEN pb.from_start_date AND pb.to_end_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS period_credits
    FROM   base_trx b
    JOIN   ar_receivable_applications_all app
           ON app.payment_schedule_id = b.payment_schedule_id
    JOIN   ra_customer_trx_all rct_cm
           ON rct_cm.customer_trx_id = app.applied_customer_trx_id
          AND rct_cm.trx_type IN ('CM','ADJ')
    JOIN   xla_distribution_links xdl
           ON xdl.source_distribution_type = 'AR_RECEIVABLE_APPLICATIONS'
          AND xdl.source_distribution_id_num_1 = app.receivable_application_id
    JOIN   xla_ae_lines xala
           ON xala.ae_header_id = xdl.ae_header_id
          AND xala.ae_line_num  = xdl.ae_line_num
    JOIN   xla_ae_headers xae
           ON xae.ae_header_id = xala.ae_header_id
    JOIN   gl_code_combinations gcc
           ON gcc.code_combination_id = xala.code_combination_id
    CROSS JOIN period_bounds pb
    WHERE  xae.ledger_id            = :p_ledger_id
    AND    xala.accounting_class_code = 'REC'
    AND    app.application_type      = 'CREDIT_MEMO'
    GROUP BY b.customer_trx_id,
             gcc.segment5
),

adjustments AS (
    SELECT b.customer_trx_id,
           gcc.segment5,
           SUM(CASE
                 WHEN xae.accounting_date <= pb.opening_as_of_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS opening_adjustments,
           SUM(CASE
                 WHEN xae.accounting_date BETWEEN pb.from_start_date AND pb.to_end_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS period_adjustments
    FROM   base_trx b
    JOIN   ar_adjustments_all adj
           ON adj.customer_trx_id = b.customer_trx_id
    JOIN   xla_distribution_links xdl
           ON xdl.source_distribution_type = 'AR_ADJUSTMENTS'
          AND xdl.source_distribution_id_num_1 = adj.adjustment_id
    JOIN   xla_ae_lines xala
           ON xala.ae_header_id = xdl.ae_header_id
          AND xala.ae_line_num  = xdl.ae_line_num
    JOIN   xla_ae_headers xae
           ON xae.ae_header_id = xala.ae_header_id
    JOIN   gl_code_combinations gcc
           ON gcc.code_combination_id = xala.code_combination_id
    CROSS JOIN period_bounds pb
    WHERE  xae.ledger_id            = :p_ledger_id
    AND    xala.accounting_class_code = 'REC'
    GROUP BY b.customer_trx_id,
             gcc.segment5
),

receivables_activities AS (
    SELECT b.customer_trx_id,
           gcc.segment5,
           SUM(CASE
                 WHEN xae.accounting_date <= pb.opening_as_of_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS opening_activities,
           SUM(CASE
                 WHEN xae.accounting_date BETWEEN pb.from_start_date AND pb.to_end_date
                 THEN xala.accounted_dr - xala.accounted_cr
                 ELSE 0
               END) AS period_activities
    FROM   base_trx b
    JOIN   ar_receivables_trx_all art
           ON art.customer_trx_id = b.customer_trx_id
    JOIN   xla_distribution_links xdl
           ON xdl.source_distribution_type = 'AR_RECEIVABLES_TRX'
          AND xdl.source_distribution_id_num_1 = art.receivables_trx_id
    JOIN   xla_ae_lines xala
           ON xala.ae_header_id = xdl.ae_header_id
          AND xala.ae_line_num  = xdl.ae_line_num
    JOIN   xla_ae_headers xae
           ON xae.ae_header_id = xala.ae_header_id
    JOIN   gl_code_combinations gcc
           ON gcc.code_combination_id = xala.code_combination_id
    CROSS JOIN period_bounds pb
    WHERE  xae.ledger_id            = :p_ledger_id
    AND    xala.accounting_class_code = 'REC'
    GROUP BY b.customer_trx_id,
             gcc.segment5
),

roll AS (
    SELECT b.customer_trx_id,
           b.trx_number,
           b.trx_date,
           b.bill_to_customer_id,
           b.trx_type,
           b.invoice_currency_code,
           COALESCE(ia.segment5, cr.segment5, cm.segment5, adj.segment5, ra.segment5) AS segment5,
           NVL(ia.opening_invoiced,0)       AS opening_invoiced,
           NVL(cr.opening_receipts,0)       AS opening_receipts,
           NVL(cm.opening_credits,0)        AS opening_credits,
           NVL(adj.opening_adjustments,0)   AS opening_adjustments,
           NVL(ra.opening_activities,0)     AS opening_activities,
           NVL(ia.period_invoiced,0)        AS period_invoiced,
           NVL(cr.period_receipts,0)        AS period_receipts,
           NVL(cm.period_credits,0)         AS period_credits,
           NVL(adj.period_adjustments,0)    AS period_adjustments,
           NVL(ra.period_activities,0)      AS period_activities
    FROM   base_trx b
    LEFT JOIN inv_acct ia
           ON ia.customer_trx_id = b.customer_trx_id
    LEFT JOIN cash_receipts cr
           ON cr.customer_trx_id = b.customer_trx_id
          AND (ia.segment5 = cr.segment5 OR ia.segment5 IS NULL OR cr.segment5 IS NULL)
    LEFT JOIN credit_memos cm
           ON cm.customer_trx_id = b.customer_trx_id
          AND (ia.segment5 = cm.segment5 OR ia.segment5 IS NULL OR cm.segment5 IS NULL)
    LEFT JOIN adjustments adj
           ON adj.customer_trx_id = b.customer_trx_id
          AND (ia.segment5 = adj.segment5 OR ia.segment5 IS NULL OR adj.segment5 IS NULL)
    LEFT JOIN receivables_activities ra
           ON ra.customer_trx_id = b.customer_trx_id
          AND (ia.segment5 = ra.segment5 OR ia.segment5 IS NULL OR ra.segment5 IS NULL)
)

SELECT r.customer_trx_id,
       r.trx_number,
       r.trx_date,
       r.bill_to_customer_id,
       r.trx_type,
       r.invoice_currency_code,
       r.segment5,
       ( r.opening_invoiced
       + r.opening_receipts
       + r.opening_credits
       + r.opening_adjustments
       + r.opening_activities )              AS opening_balance,
       r.period_invoiced                     AS additions_in_period,
       r.period_receipts                     AS cash_receipts_in_period,
       r.period_credits                      AS credit_memos_in_period,
       r.period_adjustments                  AS adjustments_in_period,
       r.period_activities                   AS receivables_activities_in_period,
       ( r.period_receipts
       + r.period_credits
       + r.period_adjustments
       + r.period_activities )               AS total_reductions_in_period,
       ( r.opening_invoiced
       + r.opening_receipts
       + r.opening_credits
       + r.opening_adjustments
       + r.opening_activities
       + r.period_invoiced
       + r.period_receipts
       + r.period_credits
       + r.period_adjustments
       + r.period_activities )               AS ending_balance
FROM   roll r
ORDER BY r.segment5,
         r.trx_date,
         r.customer_trx_id;
