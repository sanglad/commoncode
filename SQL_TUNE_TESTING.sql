-- ============================================================================
-- Oracle Fusion Cloud: User, Role, Privilege & Action Queries
-- ============================================================================
-- These queries run against Oracle Fusion application database tables to
-- retrieve the security chain: User -> Role -> Privilege -> Action.
--
-- Core Tables Used:
--   FUSION.ASE_USER_VL          - User details
--   FUSION.ASE_USER_ROLE_MBR    - User-to-role assignments
--   FUSION.ASE_ROLE_VL          - Role definitions (name, code, type)
--   FUSION.ASE_ROLE_ROLE_MBR    - Role hierarchy (parent-child relationships)
--   FUSION.ASE_PRIV_ROLE_MBR    - Privilege-to-role mapping
--   FUSION.ASE_PRIVILEGE_VL     - Privilege definitions
--   FUSION.ASE_PERMISSION_B     - Permissions (resource type, action)
--   FUSION.ASE_ROLE_TYPE_VL     - Role type labels (Job, Duty, Abstract, etc.)
-- ============================================================================


-- ============================================================================
-- QUERY 1: Users and Their Assigned Roles
-- Returns every active user along with the roles directly assigned to them.
-- ============================================================================
SELECT u.user_id,
       u.user_display_name                       AS user_display_name,
       u.user_name                               AS user_name,
       r.role_id,
       r.role_name,
       r.role_code,
       r.description                             AS role_description,
       urm.effective_start_date                  AS role_assigned_from,
       urm.effective_end_date                    AS role_assigned_to
  FROM fusion.ase_user_role_mbr   urm
  JOIN fusion.ase_user_vl         u   ON u.user_id = urm.user_id
  JOIN fusion.ase_role_vl         r   ON r.role_id = urm.role_id
 WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
 ORDER BY u.user_display_name, r.role_name;


-- ============================================================================
-- QUERY 2: Role Hierarchy (Job Role -> Duty Roles -> Nested Roles)
-- Traverses the role-to-role membership to show the inheritance chain.
-- ============================================================================
SELECT LEVEL                                     AS hierarchy_level,
       LPAD(' ', (LEVEL - 1) * 3, ' ') || cr.role_name
                                                 AS indented_role_name,
       cr.role_code,
       cr.description                            AS role_description,
       SYS_CONNECT_BY_PATH(cr.role_name, ' -> ') AS role_path,
       pr.role_name                              AS parent_role_name,
       rrm.effective_start_date,
       rrm.effective_end_date
  FROM fusion.ase_role_role_mbr   rrm
  JOIN fusion.ase_role_vl         cr  ON cr.role_id = rrm.child_role_id
  JOIN fusion.ase_role_vl         pr  ON pr.role_id = rrm.parent_role_id
 WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
 START WITH rrm.parent_role_id IN (
       SELECT role_id FROM fusion.ase_role_vl
       -- Optionally filter to a specific top-level role:
       -- WHERE role_code = 'ORA_XX_YOUR_JOB_ROLE'
 )
 CONNECT BY PRIOR rrm.child_role_id = rrm.parent_role_id
 ORDER SIBLINGS BY cr.role_name;


-- ============================================================================
-- QUERY 3: Privileges and Their Actions / Permissions
-- Lists every privilege with the resource type and action it grants.
-- ============================================================================
SELECT p.privilege_id,
       p.code                                    AS privilege_code,
       pt.name                                   AS privilege_name,
       perm.code                                 AS permission_code,
       perm.resource_type_name,
       perm.action,
       perm.effective_start_date                 AS permission_start_date,
       perm.effective_end_date                   AS permission_end_date
  FROM fusion.ase_privilege_b     p
  JOIN fusion.ase_privilege_tl    pt   ON pt.privilege_id = p.privilege_id
                                      AND pt.language     = 'US'
  JOIN fusion.ase_permission_b    perm ON perm.privilege_id = p.privilege_id
 WHERE SYSDATE BETWEEN p.effective_start_date
                    AND NVL(p.effective_end_date, SYSDATE)
   AND SYSDATE BETWEEN perm.effective_start_date
                    AND NVL(perm.effective_end_date, SYSDATE)
 ORDER BY p.code, perm.action;


-- ============================================================================
-- QUERY 4: Roles and Their Associated Privileges
-- Maps each role to the privileges it grants.
-- ============================================================================
SELECT r.role_name,
       r.role_code,
       pv.privilege_name,
       pv.privilege_code,
       pv.description                            AS privilege_description,
       prm.effective_start_date,
       prm.effective_end_date
  FROM fusion.ase_priv_role_mbr   prm
  JOIN fusion.ase_role_vl         r   ON r.role_id      = prm.role_id
  JOIN fusion.ase_privilege_vl    pv  ON pv.privilege_id = prm.privilege_id
 WHERE (prm.effective_end_date >= SYSDATE OR prm.effective_end_date IS NULL)
 ORDER BY r.role_name, pv.privilege_name;


-- ============================================================================
-- QUERY 5 (FULL CHAIN): User -> Role -> Privilege -> Action
-- The comprehensive query that ties everything together:
--   User -> directly assigned Role -> inherited Duty/Child Roles
--        -> Privileges on those Roles -> Permission Actions
-- ============================================================================
WITH user_roles (user_id, top_role_id, ur_start, ur_end) AS (
    SELECT urm.user_id,
           urm.role_id,
           urm.effective_start_date,
           urm.effective_end_date
      FROM fusion.ase_user_role_mbr urm
     WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
),
role_tree (user_id, top_role_id, effective_role_id, depth) AS (
    SELECT ur.user_id,
           ur.top_role_id,
           ur.top_role_id,
           1
      FROM user_roles ur
    UNION ALL
    SELECT rt.user_id,
           rt.top_role_id,
           rrm.child_role_id,
           rt.depth + 1
      FROM role_tree rt
      JOIN fusion.ase_role_role_mbr rrm
        ON rrm.parent_role_id = rt.effective_role_id
     WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
       AND rt.depth < 10
)
SELECT DISTINCT
       u.user_name,
       u.user_display_name,
       top_r.role_name                           AS assigned_role,
       top_r.role_code                           AS assigned_role_code,
       eff_r.role_name                           AS effective_role,
       eff_r.role_code                           AS effective_role_code,
       pv.privilege_name,
       pv.privilege_code,
       perm.resource_type_name,
       perm.action
  FROM role_tree                  rt
  JOIN fusion.ase_user_vl         u      ON u.user_id       = rt.user_id
  JOIN fusion.ase_role_vl         top_r  ON top_r.role_id   = rt.top_role_id
  JOIN fusion.ase_role_vl         eff_r  ON eff_r.role_id   = rt.effective_role_id
  LEFT JOIN fusion.ase_priv_role_mbr prm ON prm.role_id     = rt.effective_role_id
                                        AND (prm.effective_end_date >= SYSDATE
                                             OR prm.effective_end_date IS NULL)
  LEFT JOIN fusion.ase_privilege_vl  pv  ON pv.privilege_id  = prm.privilege_id
  LEFT JOIN fusion.ase_permission_b  perm ON perm.privilege_id = prm.privilege_id
                                         AND SYSDATE BETWEEN perm.effective_start_date
                                                         AND NVL(perm.effective_end_date, SYSDATE)
 ORDER BY u.user_display_name,
          top_r.role_name,
          eff_r.role_name,
          pv.privilege_name,
          perm.action;


-- ============================================================================
-- QUERY 6 (FILTERED): Full Chain for a Specific User
-- Replace 'JOHN.DOE' with the target username.
-- ============================================================================
WITH user_roles (user_id, top_role_id) AS (
    SELECT urm.user_id,
           urm.role_id
      FROM fusion.ase_user_role_mbr urm
     WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
),
role_tree (user_id, top_role_id, effective_role_id, depth) AS (
    SELECT ur.user_id,
           ur.top_role_id,
           ur.top_role_id,
           1
      FROM user_roles ur
    UNION ALL
    SELECT rt.user_id,
           rt.top_role_id,
           rrm.child_role_id,
           rt.depth + 1
      FROM role_tree rt
      JOIN fusion.ase_role_role_mbr rrm
        ON rrm.parent_role_id = rt.effective_role_id
     WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
       AND rt.depth < 10
)
SELECT DISTINCT
       u.user_name,
       u.user_display_name,
       top_r.role_name                           AS assigned_role,
       top_r.role_code                           AS assigned_role_code,
       eff_r.role_name                           AS effective_role,
       eff_r.role_code                           AS effective_role_code,
       pv.privilege_name,
       pv.privilege_code,
       perm.resource_type_name,
       perm.action
  FROM role_tree                  rt
  JOIN fusion.ase_user_vl         u      ON u.user_id       = rt.user_id
  JOIN fusion.ase_role_vl         top_r  ON top_r.role_id   = rt.top_role_id
  JOIN fusion.ase_role_vl         eff_r  ON eff_r.role_id   = rt.effective_role_id
  LEFT JOIN fusion.ase_priv_role_mbr prm ON prm.role_id     = rt.effective_role_id
                                        AND (prm.effective_end_date >= SYSDATE
                                             OR prm.effective_end_date IS NULL)
  LEFT JOIN fusion.ase_privilege_vl  pv  ON pv.privilege_id  = prm.privilege_id
  LEFT JOIN fusion.ase_permission_b  perm ON perm.privilege_id = prm.privilege_id
                                         AND SYSDATE BETWEEN perm.effective_start_date
                                                         AND NVL(perm.effective_end_date, SYSDATE)
 WHERE u.user_name = 'JOHN.DOE'   -- <<< Replace with the target username
 ORDER BY top_r.role_name,
          eff_r.role_name,
          pv.privilege_name,
          perm.action;


-- ============================================================================
-- QUERY 7: Data Security Grants (FND_GRANTS)
-- Shows who can do what on which data objects via data security policies.
-- ============================================================================
SELECT g.grantee_key,
       g.grantee_type,
       g.instance_type,
       obj.obj_name                              AS secured_object,
       obj.display_name                          AS object_display_name,
       m.menu_name                               AS aggregate_privilege,
       me.function_id,
       ff.function_name                          AS function_privilege,
       ff.user_function_name                     AS function_display_name,
       g.start_date,
       g.end_date
  FROM fusion.fnd_grants          g
  JOIN fusion.fnd_objects         obj  ON obj.object_id   = g.object_id
  LEFT JOIN fusion.fnd_menus      m    ON m.menu_id       = g.menu_id
  LEFT JOIN fusion.fnd_menu_entries me ON me.menu_id      = g.menu_id
  LEFT JOIN fusion.fnd_form_functions ff ON ff.function_id = me.function_id
 WHERE (g.end_date >= SYSDATE OR g.end_date IS NULL)
 ORDER BY g.grantee_key, obj.obj_name, ff.function_name;


-- ============================================================================
-- ============================================================================
-- GENERAL ACCOUNTING DASHBOARD - SPECIFIC QUERIES
-- ============================================================================
-- The "General Accounting" navigator group in Oracle Fusion is controlled by
-- job roles like "General Accountant" (ORA_GL_GENERAL_ACCOUNTANT_JOB) and
-- "General Accounting Manager" (ORA_GL_GENERAL_ACCOUNTING_MANAGER_JOB).
--
-- These job roles inherit duty roles such as:
--   - Journal Management, Import Journal, GL Reporting, etc.
-- Each duty role holds privileges that map to individual tasks (e.g.
--   "Create Journal", "Manage Journals", "Post Journals").
--
-- The queries below answer:
--   "If a user has the General Accounting Dashboard, what tasks can they do?"
-- ============================================================================


-- ============================================================================
-- QUERY 8: Navigator Menu Group -> Tasks (FND Tables)
-- Lists every task (function) inside the "General Accounting" navigator
-- menu group by walking the FND_MENUS / FND_MENU_ENTRIES hierarchy.
-- If your menu group has a different name, adjust the WHERE clause.
-- ============================================================================
SELECT LEVEL                                         AS menu_depth,
       LPAD(' ', (LEVEL - 1) * 3) || fmev.prompt    AS task_name,
       fmev.entry_sequence,
       fmev.description                              AS task_description,
       fffv.function_name                            AS function_code,
       fffv.user_function_name                       AS function_display_name,
       fffv.type                                     AS function_type,
       sub_menu.user_menu_name                       AS sub_menu_name
  FROM fusion.fnd_menu_entries_vl  fmev
  LEFT JOIN fusion.fnd_form_functions_vl fffv
         ON fffv.function_id = fmev.function_id
  LEFT JOIN fusion.fnd_menus_vl    sub_menu
         ON sub_menu.menu_id = fmev.sub_menu_id
 START WITH fmev.menu_id IN (
       SELECT fmv.menu_id
         FROM fusion.fnd_menus_vl fmv
        WHERE UPPER(fmv.user_menu_name) LIKE '%GENERAL ACCOUNTING%'
           OR UPPER(fmv.menu_name)      LIKE '%GENERAL_ACCOUNTING%'
 )
 CONNECT BY PRIOR fmev.sub_menu_id = fmev.menu_id
 ORDER SIBLINGS BY fmev.entry_sequence;


-- ============================================================================
-- QUERY 9: General Accountant Role -> Duty Roles -> Privileges -> Actions
-- Walks the full hierarchy starting from the "General Accountant" job role
-- down through its duty roles to every privilege and its permitted actions.
--
-- Change the role_code filter for "General Accounting Manager" or any other
-- role: ORA_GL_GENERAL_ACCOUNTING_MANAGER_JOB
-- ============================================================================
WITH role_tree (top_role_id, effective_role_id, role_path, depth) AS (
    SELECT r.role_id,
           r.role_id,
           r.role_name,
           1
      FROM fusion.ase_role_vl r
     WHERE r.role_code IN (
               'ORA_GL_GENERAL_ACCOUNTANT_JOB',
               'ORA_GL_GENERAL_ACCOUNTING_MANAGER_JOB'
           )
    UNION ALL
    SELECT rt.top_role_id,
           rrm.child_role_id,
           rt.role_path || ' -> ' || cr.role_name,
           rt.depth + 1
      FROM role_tree rt
      JOIN fusion.ase_role_role_mbr rrm
        ON rrm.parent_role_id = rt.effective_role_id
      JOIN fusion.ase_role_vl cr
        ON cr.role_id = rrm.child_role_id
     WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
       AND rt.depth < 10
)
SELECT DISTINCT
       top_r.role_name                               AS job_role,
       top_r.role_code                               AS job_role_code,
       eff_r.role_name                               AS duty_role,
       eff_r.role_code                               AS duty_role_code,
       rt.role_path                                  AS inheritance_path,
       pv.privilege_name                             AS task_privilege,
       pv.privilege_code,
       pv.description                               AS privilege_description,
       perm.resource_type_name,
       perm.action
  FROM role_tree rt
  JOIN fusion.ase_role_vl         top_r  ON top_r.role_id  = rt.top_role_id
  JOIN fusion.ase_role_vl         eff_r  ON eff_r.role_id  = rt.effective_role_id
  LEFT JOIN fusion.ase_priv_role_mbr prm ON prm.role_id    = rt.effective_role_id
                                        AND (prm.effective_end_date >= SYSDATE
                                             OR prm.effective_end_date IS NULL)
  LEFT JOIN fusion.ase_privilege_vl  pv  ON pv.privilege_id = prm.privilege_id
  LEFT JOIN fusion.ase_permission_b  perm
         ON perm.privilege_id = prm.privilege_id
        AND SYSDATE BETWEEN perm.effective_start_date
                        AND NVL(perm.effective_end_date, SYSDATE)
 ORDER BY top_r.role_name,
          rt.role_path,
          pv.privilege_name,
          perm.action;


-- ============================================================================
-- QUERY 10: For a Specific User -> General Accounting Tasks They Can Perform
-- Finds a user, walks their roles through the GL-related hierarchy, and
-- returns every privilege/action they hold under General Accounting.
--
-- Replace 'JOHN.DOE' with the actual username.
-- ============================================================================
WITH user_gl_roles (user_id, top_role_id) AS (
    SELECT urm.user_id,
           urm.role_id
      FROM fusion.ase_user_role_mbr urm
      JOIN fusion.ase_role_vl       r ON r.role_id = urm.role_id
     WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
       AND (   UPPER(r.role_name) LIKE '%GENERAL ACCOUNT%'
            OR UPPER(r.role_code) LIKE '%GL_%'
            OR UPPER(r.role_name) LIKE '%GENERAL LEDGER%')
),
role_tree (user_id, top_role_id, effective_role_id, depth) AS (
    SELECT ur.user_id,
           ur.top_role_id,
           ur.top_role_id,
           1
      FROM user_gl_roles ur
    UNION ALL
    SELECT rt.user_id,
           rt.top_role_id,
           rrm.child_role_id,
           rt.depth + 1
      FROM role_tree rt
      JOIN fusion.ase_role_role_mbr rrm
        ON rrm.parent_role_id = rt.effective_role_id
     WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
       AND rt.depth < 10
)
SELECT DISTINCT
       u.user_name,
       u.user_display_name,
       top_r.role_name                               AS assigned_gl_role,
       top_r.role_code                               AS assigned_gl_role_code,
       eff_r.role_name                               AS effective_duty_role,
       eff_r.role_code                               AS effective_duty_role_code,
       pv.privilege_name                             AS task_privilege,
       pv.privilege_code,
       pv.description                               AS task_description,
       perm.resource_type_name,
       perm.action
  FROM role_tree                  rt
  JOIN fusion.ase_user_vl         u      ON u.user_id      = rt.user_id
  JOIN fusion.ase_role_vl         top_r  ON top_r.role_id  = rt.top_role_id
  JOIN fusion.ase_role_vl         eff_r  ON eff_r.role_id  = rt.effective_role_id
  LEFT JOIN fusion.ase_priv_role_mbr prm ON prm.role_id    = rt.effective_role_id
                                        AND (prm.effective_end_date >= SYSDATE
                                             OR prm.effective_end_date IS NULL)
  LEFT JOIN fusion.ase_privilege_vl  pv  ON pv.privilege_id = prm.privilege_id
  LEFT JOIN fusion.ase_permission_b  perm
         ON perm.privilege_id = prm.privilege_id
        AND SYSDATE BETWEEN perm.effective_start_date
                        AND NVL(perm.effective_end_date, SYSDATE)
 WHERE u.user_name = 'JOHN.DOE'   -- <<< Replace with the target username
 ORDER BY top_r.role_name,
          eff_r.role_name,
          pv.privilege_name,
          perm.action;


-- ============================================================================
-- QUERY 11: All Users Who Have Access to General Accounting Dashboard
-- Lists every user who holds a General Accounting-related role, plus the
-- duty roles and privileges they inherit from it.
-- ============================================================================
WITH ga_users (user_id, top_role_id) AS (
    SELECT urm.user_id,
           urm.role_id
      FROM fusion.ase_user_role_mbr urm
      JOIN fusion.ase_role_vl       r ON r.role_id = urm.role_id
     WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
       AND (   UPPER(r.role_name) LIKE '%GENERAL ACCOUNT%'
            OR UPPER(r.role_code) LIKE '%GL_%'
            OR UPPER(r.role_name) LIKE '%GENERAL LEDGER%')
),
role_tree (user_id, top_role_id, effective_role_id, depth) AS (
    SELECT ga.user_id,
           ga.top_role_id,
           ga.top_role_id,
           1
      FROM ga_users ga
    UNION ALL
    SELECT rt.user_id,
           rt.top_role_id,
           rrm.child_role_id,
           rt.depth + 1
      FROM role_tree rt
      JOIN fusion.ase_role_role_mbr rrm
        ON rrm.parent_role_id = rt.effective_role_id
     WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
       AND rt.depth < 10
)
SELECT DISTINCT
       u.user_name,
       u.user_display_name,
       top_r.role_name                               AS gl_role,
       eff_r.role_name                               AS duty_role,
       pv.privilege_name                             AS task_privilege,
       pv.privilege_code,
       perm.action
  FROM role_tree                  rt
  JOIN fusion.ase_user_vl         u      ON u.user_id      = rt.user_id
  JOIN fusion.ase_role_vl         top_r  ON top_r.role_id  = rt.top_role_id
  JOIN fusion.ase_role_vl         eff_r  ON eff_r.role_id  = rt.effective_role_id
  LEFT JOIN fusion.ase_priv_role_mbr prm ON prm.role_id    = rt.effective_role_id
                                        AND (prm.effective_end_date >= SYSDATE
                                             OR prm.effective_end_date IS NULL)
  LEFT JOIN fusion.ase_privilege_vl  pv  ON pv.privilege_id = prm.privilege_id
  LEFT JOIN fusion.ase_permission_b  perm
         ON perm.privilege_id = prm.privilege_id
        AND SYSDATE BETWEEN perm.effective_start_date
                        AND NVL(perm.effective_end_date, SYSDATE)
 ORDER BY u.user_display_name,
          top_r.role_name,
          eff_r.role_name,
          pv.privilege_name,
          perm.action;


-- ============================================================================
-- ============================================================================
-- UNIFIED QUERIES: User -> Role -> Privilege -> Menu / Function Access
-- ============================================================================
-- These queries combine the ASE security chain (users, roles, privileges,
-- actions) with the FND menu chain (grants, menus, menu entries, functions)
-- into a single result set.
--
-- Bridge between the two:
--   FND_GRANTS.grantee_key  =  ASE_ROLE_VL.role_code
--   FND_GRANTS.menu_id      -> FND_MENUS (aggregate privilege / menu group)
--   FND_MENU_ENTRIES         -> individual function entries in that menu
--   FND_FORM_FUNCTIONS       -> page / taskflow / URL the user can access
-- ============================================================================


-- ============================================================================
-- QUERY 12: COMPLETE VIEW - User, Role, Privilege, Action, Menu & Function
-- Shows every user with:
--   * Their directly assigned role
--   * The effective (inherited) duty role holding the privilege
--   * The privilege name, code, and permitted action
--   * The menu (aggregate privilege) granted to that role via FND_GRANTS
--   * Each function/page inside that menu the user can reach
-- ============================================================================
WITH user_roles (user_id, top_role_id) AS (
    SELECT urm.user_id,
           urm.role_id
      FROM fusion.ase_user_role_mbr urm
     WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
),
role_tree (user_id, top_role_id, effective_role_id, depth) AS (
    SELECT ur.user_id,
           ur.top_role_id,
           ur.top_role_id,
           1
      FROM user_roles ur
    UNION ALL
    SELECT rt.user_id,
           rt.top_role_id,
           rrm.child_role_id,
           rt.depth + 1
      FROM role_tree rt
      JOIN fusion.ase_role_role_mbr rrm
        ON rrm.parent_role_id = rt.effective_role_id
     WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
       AND rt.depth < 10
)
SELECT DISTINCT
       u.user_name,
       u.user_display_name,
       -- Role info
       top_r.role_name                               AS assigned_role,
       top_r.role_code                               AS assigned_role_code,
       eff_r.role_name                               AS effective_role,
       eff_r.role_code                               AS effective_role_code,
       -- Privilege & action
       pv.privilege_name,
       pv.privilege_code,
       perm.resource_type_name,
       perm.action,
       -- Menu access (aggregate privilege)
       m.menu_name                                   AS menu_name,
       -- Function / page details
       ff.function_name                              AS function_code,
       ff.user_function_name                         AS function_display_name,
       ff.type                                       AS function_type,
       ff.web_html_call                              AS function_url,
       ff.description                                AS function_description
  FROM role_tree                  rt
  JOIN fusion.ase_user_vl         u      ON u.user_id      = rt.user_id
  JOIN fusion.ase_role_vl         top_r  ON top_r.role_id  = rt.top_role_id
  JOIN fusion.ase_role_vl         eff_r  ON eff_r.role_id  = rt.effective_role_id
  -- Privileges on the effective role
  LEFT JOIN fusion.ase_priv_role_mbr prm
         ON prm.role_id = rt.effective_role_id
        AND (prm.effective_end_date >= SYSDATE OR prm.effective_end_date IS NULL)
  LEFT JOIN fusion.ase_privilege_vl  pv
         ON pv.privilege_id = prm.privilege_id
  LEFT JOIN fusion.ase_permission_b  perm
         ON perm.privilege_id = prm.privilege_id
        AND SYSDATE BETWEEN perm.effective_start_date
                        AND NVL(perm.effective_end_date, SYSDATE)
  -- Menu / function access granted to the effective role
  LEFT JOIN fusion.fnd_grants g
         ON g.grantee_key = eff_r.role_code
        AND (g.end_date >= SYSDATE OR g.end_date IS NULL)
  LEFT JOIN fusion.fnd_menus m
         ON m.menu_id = g.menu_id
  LEFT JOIN fusion.fnd_menu_entries me
         ON me.menu_id = m.menu_id
  LEFT JOIN fusion.fnd_form_functions ff
         ON ff.function_id = me.function_id
 ORDER BY u.user_display_name,
          top_r.role_name,
          eff_r.role_name,
          pv.privilege_name,
          m.menu_name,
          ff.user_function_name;


-- ============================================================================
-- QUERY 13: COMPLETE VIEW FOR A SPECIFIC USER
-- Same as Query 12 but filtered by username.
-- Replace 'JOHN.DOE' with the target username.
-- ============================================================================
WITH user_roles (user_id, top_role_id) AS (
    SELECT urm.user_id,
           urm.role_id
      FROM fusion.ase_user_role_mbr urm
     WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
),
role_tree (user_id, top_role_id, effective_role_id, depth) AS (
    SELECT ur.user_id,
           ur.top_role_id,
           ur.top_role_id,
           1
      FROM user_roles ur
    UNION ALL
    SELECT rt.user_id,
           rt.top_role_id,
           rrm.child_role_id,
           rt.depth + 1
      FROM role_tree rt
      JOIN fusion.ase_role_role_mbr rrm
        ON rrm.parent_role_id = rt.effective_role_id
     WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
       AND rt.depth < 10
)
SELECT DISTINCT
       u.user_name,
       u.user_display_name,
       top_r.role_name                               AS assigned_role,
       top_r.role_code                               AS assigned_role_code,
       eff_r.role_name                               AS effective_role,
       eff_r.role_code                               AS effective_role_code,
       pv.privilege_name,
       pv.privilege_code,
       perm.resource_type_name,
       perm.action,
       m.menu_name                                   AS menu_name,
       ff.function_name                              AS function_code,
       ff.user_function_name                         AS function_display_name,
       ff.type                                       AS function_type,
       ff.web_html_call                              AS function_url,
       ff.description                                AS function_description
  FROM role_tree                  rt
  JOIN fusion.ase_user_vl         u      ON u.user_id      = rt.user_id
  JOIN fusion.ase_role_vl         top_r  ON top_r.role_id  = rt.top_role_id
  JOIN fusion.ase_role_vl         eff_r  ON eff_r.role_id  = rt.effective_role_id
  LEFT JOIN fusion.ase_priv_role_mbr prm
         ON prm.role_id = rt.effective_role_id
        AND (prm.effective_end_date >= SYSDATE OR prm.effective_end_date IS NULL)
  LEFT JOIN fusion.ase_privilege_vl  pv
         ON pv.privilege_id = prm.privilege_id
  LEFT JOIN fusion.ase_permission_b  perm
         ON perm.privilege_id = prm.privilege_id
        AND SYSDATE BETWEEN perm.effective_start_date
                        AND NVL(perm.effective_end_date, SYSDATE)
  LEFT JOIN fusion.fnd_grants g
         ON g.grantee_key = eff_r.role_code
        AND (g.end_date >= SYSDATE OR g.end_date IS NULL)
  LEFT JOIN fusion.fnd_menus m
         ON m.menu_id = g.menu_id
  LEFT JOIN fusion.fnd_menu_entries me
         ON me.menu_id = m.menu_id
  LEFT JOIN fusion.fnd_form_functions ff
         ON ff.function_id = me.function_id
 WHERE u.user_name = 'JOHN.DOE'   -- <<< Replace with the target username
 ORDER BY top_r.role_name,
          eff_r.role_name,
          pv.privilege_name,
          m.menu_name,
          ff.user_function_name;


-- ============================================================================
-- QUERY 14: ROLE-ONLY VIEW - Role, Privilege, Menu & Function (No User Filter)
-- Useful when you just want to see what a specific ROLE grants, without
-- tying it to a user. Shows the role's inherited duty roles, their
-- privileges, actions, and menu/function access.
--
-- Replace the role_code value as needed.
-- ============================================================================
WITH role_tree (top_role_id, effective_role_id, role_path, depth) AS (
    SELECT r.role_id,
           r.role_id,
           r.role_name,
           1
      FROM fusion.ase_role_vl r
     WHERE r.role_code = 'ORA_GL_GENERAL_ACCOUNTANT_JOB'  -- <<< Replace
    UNION ALL
    SELECT rt.top_role_id,
           rrm.child_role_id,
           rt.role_path || ' > ' || cr.role_name,
           rt.depth + 1
      FROM role_tree rt
      JOIN fusion.ase_role_role_mbr rrm
        ON rrm.parent_role_id = rt.effective_role_id
      JOIN fusion.ase_role_vl cr
        ON cr.role_id = rrm.child_role_id
     WHERE (rrm.effective_end_date >= SYSDATE OR rrm.effective_end_date IS NULL)
       AND rt.depth < 10
)
SELECT DISTINCT
       top_r.role_name                               AS job_role,
       top_r.role_code                               AS job_role_code,
       eff_r.role_name                               AS effective_role,
       eff_r.role_code                               AS effective_role_code,
       rt.role_path                                  AS inheritance_path,
       pv.privilege_name,
       pv.privilege_code,
       perm.resource_type_name,
       perm.action,
       m.menu_name                                   AS menu_name,
       ff.function_name                              AS function_code,
       ff.user_function_name                         AS function_display_name,
       ff.type                                       AS function_type,
       ff.web_html_call                              AS function_url
  FROM role_tree rt
  JOIN fusion.ase_role_vl         top_r  ON top_r.role_id  = rt.top_role_id
  JOIN fusion.ase_role_vl         eff_r  ON eff_r.role_id  = rt.effective_role_id
  LEFT JOIN fusion.ase_priv_role_mbr prm
         ON prm.role_id = rt.effective_role_id
        AND (prm.effective_end_date >= SYSDATE OR prm.effective_end_date IS NULL)
  LEFT JOIN fusion.ase_privilege_vl  pv
         ON pv.privilege_id = prm.privilege_id
  LEFT JOIN fusion.ase_permission_b  perm
         ON perm.privilege_id = prm.privilege_id
        AND SYSDATE BETWEEN perm.effective_start_date
                        AND NVL(perm.effective_end_date, SYSDATE)
  LEFT JOIN fusion.fnd_grants g
         ON g.grantee_key = eff_r.role_code
        AND (g.end_date >= SYSDATE OR g.end_date IS NULL)
  LEFT JOIN fusion.fnd_menus m
         ON m.menu_id = g.menu_id
  LEFT JOIN fusion.fnd_menu_entries me
         ON me.menu_id = m.menu_id
  LEFT JOIN fusion.fnd_form_functions ff
         ON ff.function_id = me.function_id
 ORDER BY rt.role_path,
          pv.privilege_name,
          m.menu_name,
          ff.user_function_name;
