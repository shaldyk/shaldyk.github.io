USE [BeaconSpark_data]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- ====================================================
-- Adds the two new nullable FK-style columns to
-- tbl_bi_clicks_invalid_p that reference dbo.tbl_user_agents(ua_id),
-- mirroring the columns added to tbl_bi_clicks in
-- 02_alter_tbl_bi_clicks.sql so invalid/banned clicks can carry
-- the same User-Agent references.
--   request_ua_id - resolved from @request_ua (server/request-side UA)
--   click_ua_id   - resolved from @click_ua   (browser/click-side UA)
-- Both are nullable because the calling code may not always have
-- a UA string available.
-- ====================================================
IF NOT EXISTS (
	SELECT 1 FROM sys.columns
	WHERE object_id = OBJECT_ID('dbo.tbl_bi_clicks_invalid_p') AND name = 'request_ua_id'
)
BEGIN
	ALTER TABLE dbo.tbl_bi_clicks_invalid_p ADD request_ua_id INT NULL;
END
GO

IF NOT EXISTS (
	SELECT 1 FROM sys.columns
	WHERE object_id = OBJECT_ID('dbo.tbl_bi_clicks_invalid_p') AND name = 'click_ua_id'
)
BEGIN
	ALTER TABLE dbo.tbl_bi_clicks_invalid_p ADD click_ua_id INT NULL;
END
GO
