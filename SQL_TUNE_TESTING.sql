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
WITH user_roles AS (
    SELECT urm.user_id,
           urm.role_id                           AS top_role_id,
           urm.effective_start_date              AS ur_start,
           urm.effective_end_date                AS ur_end
      FROM fusion.ase_user_role_mbr urm
     WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
),
role_tree AS (
    SELECT ur.user_id,
           ur.top_role_id,
           ur.top_role_id                        AS effective_role_id,
           1                                     AS depth
      FROM user_roles ur
    UNION ALL
    SELECT rt.user_id,
           rt.top_role_id,
           rrm.child_role_id                     AS effective_role_id,
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
WITH user_roles AS (
    SELECT urm.user_id,
           urm.role_id                           AS top_role_id
      FROM fusion.ase_user_role_mbr urm
     WHERE (urm.effective_end_date >= SYSDATE OR urm.effective_end_date IS NULL)
),
role_tree AS (
    SELECT ur.user_id,
           ur.top_role_id,
           ur.top_role_id                        AS effective_role_id,
           1                                     AS depth
      FROM user_roles ur
    UNION ALL
    SELECT rt.user_id,
           rt.top_role_id,
           rrm.child_role_id                     AS effective_role_id,
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
