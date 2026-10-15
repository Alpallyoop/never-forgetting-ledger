The provided code snippets are part of a larger system designed for policy evaluation and management in a distributed environment. Let's break down the key components and their functionalities:

### 1. **Policy Evaluation Function (`gi_ppi_overlay_eval`)**

This function evaluates proposals based on active overlays. If no overlay is active, it returns 'NO_OP'. Otherwise, it checks if the task type in the proposal is denied by the overlay.

```sql
CREATE OR REPLACE FUNCTION gi_ppi_overlay_eval(
  p_org_id uuid,
  p_proposal jsonb
)
RETURNS TABLE (
  overlay_decision text,
  overlay_reason_codes text[],
  overlay_diagnostics jsonb
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_overlay jsonb;
  v_task_type text;
  v_denied_task_types jsonb;
BEGIN
  -- Check for active overlay
  SELECT ov.overlay_json INTO v_overlay
  FROM gi_ppi_org_overlay_active a
  JOIN gi_ppi_org_overlay_versions ov ON ov.overlay_version_id = a.overlay_version_id
  WHERE a.org_id = p_org_id;

  IF v_overlay IS NULL THEN
    RETURN QUERY
    SELECT 'NO_OP', ARRAY['overlay_noop_v0'], jsonb_build_object('note','no_active_overlay');
    RETURN;
  END IF;

  -- Extract task_type from proposal
  v_task_type := coalesce(p_proposal #>> '{inputs,task_type}', '');

  -- Deny list
  v_denied_task_types := v_overlay ->> 'deny';

  IF v_denied_task_types IS NOT NULL AND v_task_type = ANY(string_to_array(v_denied_task_types, ',')) THEN
    RETURN QUERY
    SELECT 'DENY', ARRAY['task_denied_v0'], jsonb_build_object('note','task_denied_by_overlay');
  ELSE
    RETURN QUERY
    SELECT 'ALLOW', '{}'::text[], jsonb_build_object('note','task_allowed_by_overlay');
  END IF;
END;
$$;
```

### 2. **Admin Functions for Setting Organization Plan and Publishing Overlays**

These functions allow administrative users to set an organization's plan and publish new overlays.

#### `gi_ppi_admin_set_org_plan`

This function is triggered by the PowerShell script provided in `65_admin_set_org_plan.ps1`. It sends a request to a remote API endpoint to update the organization's plan.

```powershell
#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OrgId,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$PlanCode,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$AccessToken,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OperatorUserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "00_env.ps1")
. (Join-Path $PSScriptRoot "05_http.ps1")

function New-UserAuthHeaders {
  param([string]$Jwt)
  return @{
    "apikey"        = $global:SUPABASE_ANON_KEY
    "Authorization" = "Bearer $Jwt"
    "Content-Type"  = "application/json"
  }
}

# Build request
$headersUser = New-UserAuthHeaders -Jwt $AccessToken

$bodyObj = @{
  p_org_id           = $OrgId
  p_plan_code        = $PlanCode
  p_operator_user_id = $OperatorUserId
}

$jsonBody = ($bodyObj | ConvertTo-Json -Depth 30)

Write-Verbose ("GI_PPI_ADMIN_SET_ORG_PLAN: org_id={0} plan_code={1} operator_user_id={2}" -f $OrgId, $PlanCode, $OperatorUserId)
Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_ADMIN_SET_ORG_PLAN_URI -Headers $headersUser -JsonBody $jsonBody
```

#### `gi_ppi_admin_publish_overlay`

This function publishes a new overlay for an organization.

```sql
CREATE OR REPLACE FUNCTION gi_ppi_admin_publish_overlay(
  p_org_id uuid,
  p_overlay_json jsonb,
  p_overlay_hash text,
  p_operator_user_id uuid
)
RETURNS TABLE (
  ok boolean,
  org_id uuid,
  overlay_version_id uuid,
  overlay_hash text,
  operator_user_id uuid
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_overlay jsonb;
  v_task_type text;
  v_denied_task_types jsonb;
BEGIN
  -- Check if overlay is allowed for the organization
  SELECT overlay_json INTO v_overlay
  FROM gi_ppi_org_overlay_active a
  JOIN gi_ppi_org_overlay_versions ov ON ov.overlay_version_id = a.overlay_version_id
  WHERE a.org_id = p_org_id;

  IF v_overlay IS NULL THEN
    RAISE EXCEPTION 'Overlay not entitled';
  END IF;

  -- Insert new overlay version
  INSERT INTO gi_ppi_org_overlay_versions (org_id, overlay_json, overlay_hash, created_by)
  VALUES (p_org_id, p_overlay_json, p_overlay_hash, p_operator_user_id)
  ON CONFLICT (org_id, overlay_hash) DO UPDATE
    SET overlay_json = excluded.overlay_json -- same hash => keep id stable per insert attempt
  RETURNING overlay_version_id;

  -- Update active overlay
  INSERT INTO gi_ppi_org_overlay_active (org_id, overlay_version_id, activated_by)
  VALUES (p_org_id, v_overlay_version_id, p_operator_user_id)
  ON CONFLICT (org_id) DO UPDATE
    SET overlay_version_id = excluded.overlay_version_id,
        activated_at = now(),
        activated_by = p_operator_user_id;

  RETURN QUERY
  SELECT true, p_org_id, v_overlay_version_id, p_overlay_hash, p_operator_user_id;
END;
$$;
```

### 3. **Introspection Scripts**

These scripts provide information about the database schema and constraints for various tables, which is useful for audit and debugging purposes.

#### `00_introspect_core_objects.sql`

This script introspects core objects in the 'public' schema.

```sql
-- GI/PPI introspection: canonical columns + constraints

SELECT 'governance_policy_versions.columns' AS section;
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='governance_policy_versions'
ORDER BY ordinal_position;

SELECT 'governance_policy_rules.columns' AS section;
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='governance_policy_rules'
ORDER BY ordinal_position;

SELECT 'governance_evaluations.columns' AS section;
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='governance_evaluations'
ORDER BY ordinal_position;

SELECT 'governance_reason_codes.columns' AS section;
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='governance_reason_codes'
ORDER BY ordinal_position;

SELECT 'policy_rules.constraints' AS section;
SELECT conname, pg_get_constraintdef(c.oid) AS constraint_def
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname='public' AND t.relname='governance_policy_rules'
ORDER BY conname;

SELECT 'graph_edges.constraints' AS section;
SELECT conname, pg_get_constraintdef(c.oid) AS constraint_def
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname='public' AND t.relname='governance_policy_rule_graph_edges'
ORDER BY conname;
```

#### `00_introspect_gi_ppi_objects.sql`

This script provides detailed schema information for specific tables related to the GI/PPI system.

```sql
-- GI/PPI INTROSPECTION - CANONICAL
-- Purpose: pull exact schemas/constraints for audit + debugging

SELECT 'governance_policy_versions' AS obj, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='governance_policy_versions'
ORDER BY ordinal_position;

SELECT 'governance_policy_rules' AS obj, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='governance_policy_rules'
ORDER BY ordinal_position;

SELECT 'governance_evaluations' AS obj, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='governance_evaluations'
ORDER BY ordinal_position;

SELECT conname, pg_get_constraintdef(c.oid) AS constraint_def
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname='public' AND t.relname IN ('governance_policy_versions','governance_policy_rules','governance_evaluations','governance_policy_rule_graph_nodes','governance_policy_rule_graph_edges')
ORDER BY t.relname, conname;
```

### Summary

The provided code and scripts collectively form a comprehensive system for managing and evaluating policies in a distributed environment. The key functionalities include:

- **Policy Evaluation**: Evaluating proposals against active overlays.
- **Admin Functions**: Allowing administrative users to set organization plans and publish new overlays.
- **Introspection**: Providing detailed schema information for audit and debugging purposes.

This system ensures that policies are consistently applied across the organization, enhancing security and compliance.
