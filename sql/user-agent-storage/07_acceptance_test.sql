USE [BeaconSpark_data]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

-- ====================================================
-- Acceptance test for User-Agent storage (files 01-06).
--
-- Exercises dbo.bi_click_insert_internal_v5 and, via its duplicate-click
-- path, dbo.bi_click_insert_invalid_v5, verifying the tbl_user_agents
-- get-or-create behavior and the ua_id wiring on the click tables.
--
-- SAFE TO RUN: everything happens inside a single transaction that is
-- ALWAYS rolled back at the end, so NO permanent rows are written to
-- tbl_bi_clicks, tbl_bi_clicks_invalid_p or tbl_user_agents. (IDENTITY
-- values are consumed, leaving harmless gaps.) Results are collected in a
-- table variable, which survives the rollback, and printed at the end.
--
-- Prefer to run it in a non-production environment first. If the inserts
-- fail due to FK/index specifics, set the @test_* ids below to real,
-- existing values in your environment.
-- ====================================================
SET NOCOUNT ON;

------------------------------------------------------------------
-- Test configuration - adjust if your environment needs real ids.
-- source_website_id = dest_website_id keeps it an "internal" click, so the
-- credit/transaction side-effect procs are skipped.
------------------------------------------------------------------
DECLARE
	@test_website_id INT = 1,
	@test_post_id    INT = 1,
	@test_widget_id  INT = 1;

DECLARE @results TABLE (
	test_no   INT,
	test_name VARCHAR(200),
	result    VARCHAR(4),
	detail    NVARCHAR(400)
);

-- Unique per-run tag so every UA string is guaranteed "new".
DECLARE @tag     VARCHAR(50)  = CONVERT(VARCHAR(50), NEWID());
DECLARE @ua1     VARCHAR(512) = 'ACCTEST both '    + @tag;
DECLARE @uaReq   VARCHAR(512) = 'ACCTEST request ' + @tag;
DECLARE @uaClk   VARCHAR(512) = 'ACCTEST click '   + @tag;
DECLARE @uaInv   VARCHAR(512) = 'ACCTEST invalid ' + @tag;

DECLARE
	@click_id BIGINT,
	@uaid INT, @uaid2 INT, @reqid INT, @clkid INT, @uaidInv INT,
	@cnt INT, @empty_before INT, @empty_after INT;
DECLARE @g NVARCHAR(MAX);

BEGIN TRY
	BEGIN TRAN;

	------------------------------------------------------------------
	-- TEST 1: a brand-new UA creates a tbl_user_agents row (with
	-- creation_date_time) and stores its ua_id on the click row.
	------------------------------------------------------------------
	SET @g = CONVERT(VARCHAR(50), NEWID());
	EXEC dbo.bi_click_insert_internal_v5
		@source_post_id=@test_post_id, @source_website_id=@test_website_id,
		@dest_post_id=@test_post_id,   @dest_website_id=@test_website_id,
		@visitor_guid='', @widget_id=@test_widget_id, @link_location=0,
		@country_code='US', @region_code='--', @geo_sub1_code='--', @geo_sub2_code='--',
		@click_guid=@g, @request_ua=@ua1, @click_ua=@ua1,
		@click_id=@click_id OUTPUT;

	SELECT @uaid = ua_id FROM dbo.tbl_user_agents WHERE user_agent = @ua1;

	IF @uaid IS NOT NULL
	   AND EXISTS (SELECT 1 FROM dbo.tbl_user_agents WHERE ua_id=@uaid AND creation_date_time IS NOT NULL)
	   AND EXISTS (SELECT 1 FROM dbo.tbl_bi_clicks WHERE click_id=@click_id AND request_ua_id=@uaid AND click_ua_id=@uaid)
		INSERT @results VALUES (1,'New UA: creates row (+creation_date_time) and stores ua_id on click','PASS',
			CONCAT('ua_id=',@uaid,' click_id=',@click_id));
	ELSE
		INSERT @results VALUES (1,'New UA: creates row (+creation_date_time) and stores ua_id on click','FAIL',
			CONCAT('ua_id=',ISNULL(CONVERT(VARCHAR(20),@uaid),'NULL'),' click_id=',ISNULL(CONVERT(VARCHAR(20),@click_id),'NULL')));

	------------------------------------------------------------------
	-- TEST 2: the same UA again is de-duplicated (no new row; same ua_id).
	------------------------------------------------------------------
	SET @g = CONVERT(VARCHAR(50), NEWID());
	EXEC dbo.bi_click_insert_internal_v5
		@source_post_id=@test_post_id, @source_website_id=@test_website_id,
		@dest_post_id=@test_post_id,   @dest_website_id=@test_website_id,
		@visitor_guid='', @widget_id=@test_widget_id, @link_location=0,
		@country_code='US', @region_code='--', @geo_sub1_code='--', @geo_sub2_code='--',
		@click_guid=@g, @request_ua=@ua1, @click_ua=@ua1,
		@click_id=@click_id OUTPUT;

	SELECT @cnt = COUNT(*) FROM dbo.tbl_user_agents WHERE user_agent = @ua1;
	SELECT @uaid2 = request_ua_id FROM dbo.tbl_bi_clicks WHERE click_id = @click_id;

	IF @cnt = 1 AND @uaid2 = @uaid
		INSERT @results VALUES (2,'Repeat UA: de-duplicated, existing ua_id reused','PASS',
			CONCAT('row count for UA=',@cnt,' reused ua_id=',@uaid2));
	ELSE
		INSERT @results VALUES (2,'Repeat UA: de-duplicated, existing ua_id reused','FAIL',
			CONCAT('row count for UA=',@cnt,' (expected 1) ua_id=',ISNULL(CONVERT(VARCHAR(20),@uaid2),'NULL'),' (expected ',@uaid,')'));

	------------------------------------------------------------------
	-- TEST 3: distinct request vs click UA -> two rows, mapped correctly.
	------------------------------------------------------------------
	SET @g = CONVERT(VARCHAR(50), NEWID());
	EXEC dbo.bi_click_insert_internal_v5
		@source_post_id=@test_post_id, @source_website_id=@test_website_id,
		@dest_post_id=@test_post_id,   @dest_website_id=@test_website_id,
		@visitor_guid='', @widget_id=@test_widget_id, @link_location=0,
		@country_code='US', @region_code='--', @geo_sub1_code='--', @geo_sub2_code='--',
		@click_guid=@g, @request_ua=@uaReq, @click_ua=@uaClk,
		@click_id=@click_id OUTPUT;

	SELECT @reqid = ua_id FROM dbo.tbl_user_agents WHERE user_agent = @uaReq;
	SELECT @clkid = ua_id FROM dbo.tbl_user_agents WHERE user_agent = @uaClk;

	IF @reqid IS NOT NULL AND @clkid IS NOT NULL AND @reqid <> @clkid
	   AND EXISTS (SELECT 1 FROM dbo.tbl_bi_clicks WHERE click_id=@click_id AND request_ua_id=@reqid AND click_ua_id=@clkid)
		INSERT @results VALUES (3,'Distinct request/click UA: two rows, mapped correctly','PASS',
			CONCAT('request_ua_id=',@reqid,' click_ua_id=',@clkid));
	ELSE
		INSERT @results VALUES (3,'Distinct request/click UA: two rows, mapped correctly','FAIL',
			CONCAT('request_ua_id=',ISNULL(CONVERT(VARCHAR(20),@reqid),'NULL'),' click_ua_id=',ISNULL(CONVERT(VARCHAR(20),@clkid),'NULL')));

	------------------------------------------------------------------
	-- TEST 4: NULL request UA and empty-string click UA -> both ids NULL,
	-- and no junk empty-string row is created.
	------------------------------------------------------------------
	SELECT @empty_before = COUNT(*) FROM dbo.tbl_user_agents WHERE user_agent = '';

	SET @g = CONVERT(VARCHAR(50), NEWID());
	EXEC dbo.bi_click_insert_internal_v5
		@source_post_id=@test_post_id, @source_website_id=@test_website_id,
		@dest_post_id=@test_post_id,   @dest_website_id=@test_website_id,
		@visitor_guid='', @widget_id=@test_widget_id, @link_location=0,
		@country_code='US', @region_code='--', @geo_sub1_code='--', @geo_sub2_code='--',
		@click_guid=@g, @request_ua=NULL, @click_ua='',
		@click_id=@click_id OUTPUT;

	SELECT @empty_after = COUNT(*) FROM dbo.tbl_user_agents WHERE user_agent = '';

	IF EXISTS (SELECT 1 FROM dbo.tbl_bi_clicks WHERE click_id=@click_id AND request_ua_id IS NULL AND click_ua_id IS NULL)
	   AND @empty_after = @empty_before
		INSERT @results VALUES (4,'NULL/empty UA: ids left NULL, no empty-string row created','PASS',
			CONCAT('empty-row count unchanged=',@empty_after));
	ELSE
		INSERT @results VALUES (4,'NULL/empty UA: ids left NULL, no empty-string row created','FAIL',
			CONCAT('empty rows before=',@empty_before,' after=',@empty_after,'; check click_id=',@click_id));

	------------------------------------------------------------------
	-- TEST 5: invalid path (duplicate click) populates request_ua_id in
	-- tbl_bi_clicks_invalid_p. First a normal insert, then the same
	-- click_guid again -> routed to bi_click_insert_invalid_v5 (status 5120).
	------------------------------------------------------------------
	SET @g = CONVERT(VARCHAR(50), NEWID());
	-- 5a: first (valid) insert, also creates the @uaInv row
	EXEC dbo.bi_click_insert_internal_v5
		@source_post_id=@test_post_id, @source_website_id=@test_website_id,
		@dest_post_id=@test_post_id,   @dest_website_id=@test_website_id,
		@visitor_guid='', @widget_id=@test_widget_id, @link_location=0,
		@country_code='US', @region_code='--', @geo_sub1_code='--', @geo_sub2_code='--',
		@click_guid=@g, @request_ua=@uaInv, @click_ua=@uaInv,
		@click_id=@click_id OUTPUT;

	SELECT @uaidInv = ua_id FROM dbo.tbl_user_agents WHERE user_agent = @uaInv;

	-- 5b: same click_guid -> duplicate -> invalid insert with status 5120
	EXEC dbo.bi_click_insert_internal_v5
		@source_post_id=@test_post_id, @source_website_id=@test_website_id,
		@dest_post_id=@test_post_id,   @dest_website_id=@test_website_id,
		@visitor_guid='', @widget_id=@test_widget_id, @link_location=0,
		@country_code='US', @region_code='--', @geo_sub1_code='--', @geo_sub2_code='--',
		@click_guid=@g, @request_ua=@uaInv, @click_ua=@uaInv,
		@click_id=@click_id OUTPUT;

	SELECT @cnt = COUNT(*)
	FROM dbo.tbl_bi_clicks_invalid_p
	WHERE request_ua_id = @uaidInv AND click_ua_id = @uaidInv AND click_status = 5120;

	IF @uaidInv IS NOT NULL AND @cnt >= 1
		INSERT @results VALUES (5,'Invalid/duplicate path: request_ua_id/click_ua_id populated in invalid table','PASS',
			CONCAT('invalid rows with ua_id=',@uaidInv,' status 5120 = ',@cnt));
	ELSE
		INSERT @results VALUES (5,'Invalid/duplicate path: request_ua_id/click_ua_id populated in invalid table','FAIL',
			CONCAT('ua_id=',ISNULL(CONVERT(VARCHAR(20),@uaidInv),'NULL'),' matching invalid rows=',@cnt));

	-- Undo everything - this test writes NO permanent data.
	ROLLBACK;
END TRY
BEGIN CATCH
	IF @@TRANCOUNT > 0 ROLLBACK;
	INSERT @results VALUES (0,'EXECUTION ERROR - see message','FAIL', LEFT(ERROR_MESSAGE(),400));
END CATCH;

------------------------------------------------------------------
-- Report
------------------------------------------------------------------
SELECT test_no, test_name, result, detail
FROM @results
ORDER BY test_no;

DECLARE @fail INT = (SELECT COUNT(*) FROM @results WHERE result <> 'PASS');
IF @fail = 0
	PRINT 'ACCEPTANCE TEST: ALL PASSED';
ELSE
	PRINT CONCAT('ACCEPTANCE TEST: ', @fail, ' CHECK(S) FAILED - see the result grid.');
GO
