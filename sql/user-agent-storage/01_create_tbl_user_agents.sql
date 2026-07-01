USE [BeaconSpark_data]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- ====================================================
-- Table: dbo.tbl_user_agents
-- Purpose: De-duplicated lookup table for raw User-Agent
--          strings referenced by tbl_bi_clicks
--          (request_ua_id, click_ua_id).
--
-- Design notes:
--   - user_agent carries the UNIQUE + CLUSTERED index so
--     the "does this UA already exist" lookup (step A of
--     the insert flow) is a clustered index seek.
--   - ua_id is the surrogate key returned to callers and
--     stored on tbl_bi_clicks; it is enforced as a
--     NONCLUSTERED primary key so IDENTITY lookups
--     (SCOPE_IDENTITY) stay cheap without owning the
--     clustered key.
--   - No FOREIGN KEY is created from tbl_bi_clicks to this
--     table, consistent with the existing sub_id column on
--     tbl_bi_clicks (dbo.tbl_websites_subid) - this is a
--     very high volume insert path and FK checks would add
--     avoidable overhead. Integrity is guaranteed by the
--     insert proc's get-or-create logic.
-- ====================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'tbl_user_agents' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
	CREATE TABLE dbo.tbl_user_agents (
		ua_id			INT IDENTITY(1,1)	NOT NULL,
		user_agent		VARCHAR(512)		NOT NULL,
		CONSTRAINT PK_tbl_user_agents_ua_id PRIMARY KEY NONCLUSTERED (ua_id),
		CONSTRAINT UQ_tbl_user_agents_user_agent UNIQUE CLUSTERED (user_agent)
	);
END
GO
