USE [BeaconSpark_data]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


-- ====================================================
-- Author:		Sergey
-- Create date: Aug 2021
-- v4 2026-05-19 - new input parameter @request_id
-- v5 2026-07-01 - new input parameters @request_ua, @click_ua
--                  resolved to request_ua_id/click_ua_id via
--                  dbo.tbl_user_agents (get-or-create, same
--                  pattern as the tbl_websites_subid lookup)
-- Description:
-- ====================================================
CREATE OR ALTER   PROCEDURE [dbo].[bi_click_insert_internal_v5]
	@source_post_id INT,
	@source_website_id INT,
	@dest_post_id INT,
	@dest_website_id INT,
	@visitor_guid VARCHAR (50),
	@widget_id INT,
	@link_location TINYINT,
	@country_code VARCHAR(10),
	@region_code varchar(10),
	@geo_sub1_code varchar(10),
	@geo_sub2_code varchar(10),
	@recomendation_type_id TINYINT =1,
	@cpc DECIMAL(16,4) =0, --if cpc > 0 use it, otherwise get it from tbl_website_campaigns
	@sub_id_string NVARCHAR(256) =NULL,
	@click_date DATETIME =NULL,
	@click_guid NVARCHAR(MAX)=NULL,
	@visitor_ip VARCHAR(100) = NULL,
	@request_ip VARCHAR(100) = NULL,
	@referrer NVARCHAR(MAX) = NULL,
	@device_type SMALLINT = -1,
	@device_os_family SMALLINT = -1,
	@widget_profile INT = NULL,
	@os_id SMALLINT = -1,
	@ab_test_variant int = 0,
	@rec_date_time DATETIME =NULL,
	@request_id VARCHAR(256) = '',
	@request_ua VARCHAR(512) = NULL,
	@click_ua VARCHAR(512) = NULL,
	@click_id BIGINT output
AS
BEGIN
	SET NOCOUNT ON;

	SET @click_id =0;

	DECLARE
		@v_source_publisher_id INT, @v_dest_publisher_id INT, @v_sub_id INT, @v_CPC DECIMAL(16,4) =0,
		--@v_dest_network_id INT, @v_source_network_id INT,
		@v_campaignID INT, @v_advertiserID INT, @v_adBrokerUserID INT,
		@v_click_date_time DATETIME =ISNULL(@click_date, GETDATE()), @v_billingTypeID TINYINT, @v_clickGuidHashCode INT =CHECKSUM(@click_guid),
		@v_billingPixelExists BIT = 0, @v_isBilled BIT = 1, @v_visitor_guid UNIQUEIDENTIFIER, @v_pixel_type TINYINT,
		@v_request_ua_id INT = NULL, @v_click_ua_id INT = NULL,
		@is_paid BIT;

	DECLARE @start_click_date_time DATETIME = CONVERT(DATETIME,CONVERT(DATE, DATEADD (HOUR, -8, @v_click_date_time))),
			@end_click_date_time DATETIME = CONVERT(DATETIME,CONVERT(DATE, DATEADD (HOUR, 25, @v_click_date_time)));

	SELECT
		@v_CPC = CPC, @v_campaignID = campaign_id, @v_advertiserID = advertiser_id, @v_adBrokerUserID = ad_broker_user_id,
		@v_billingTypeID = ISNULL(BillingTypeID, 1) -- if no billing type defined, use default ('Clicks')
	FROM dbo.tbl_website_campaigns AS twc WITH(NOLOCK)
	WHERE twc.website_id = @dest_website_id;

	--2022-08-30 2 steps checking duplicated clicks
	IF EXISTS (
				SELECT 1 FROM dbo.tbl_bi_clicks c WITH(NOLOCK, INDEX(IX_tbl_bi_clicks_click_guid_hash_code), FORCESEEK)
				WHERE c.click_date_time >=  @start_click_date_time AND c.click_date_time < @end_click_date_time AND
				--WHERE c.click_date_time >  DATEADD (HOUR, -8, @v_click_date_time) AND c.click_date_time <= DATEADD (HOUR, 3, @v_click_date_time) AND
				c.click_guid_hash_code =@v_clickGuidHashCode
				--AND c.click_guid = @click_guid
			)
	BEGIN
		IF EXISTS (
					SELECT 1 FROM dbo.tbl_bi_clicks c WITH(NOLOCK, INDEX(IX_tbl_bi_clicks_click_guid_hash_code), FORCESEEK)
					WHERE c.click_date_time >=  @start_click_date_time AND c.click_date_time < @end_click_date_time AND
					--WHERE c.click_date_time >  DATEADD (HOUR, -8, @v_click_date_time) AND c.click_date_time <= DATEADD (HOUR, 3, @v_click_date_time) AND
					c.click_guid_hash_code =@v_clickGuidHashCode
					AND c.click_guid = @click_guid
				)
		BEGIN
			EXEC	[dbo].[bi_click_insert_invalid_v4]
					@source_post_id,
					@source_website_id,
					@dest_post_id,
					@dest_website_id ,
					@visitor_guid,
					@widget_id,
					@link_location,
					@country_code,
					@region_code,
					@geo_sub1_code,
					@geo_sub2_code,
					@recomendation_type_id,
					@cpc,
					@sub_id_string,
					@click_date,
					@visitor_ip,
					@request_ip,
					@referrer,
					5120,		--@status,
					@device_type,
					@device_os_family,
					@widget_profile,
					@os_id,
					@click_guid,
					@ab_test_variant
					, @rec_date_time,
					@request_id
					;
			SET @click_id = SCOPE_IDENTITY();
			--SELECT 0 AS website_id,0 AS credits,0 AS paid_credits, @click_id as click_id;

			RETURN
		END
	END;

--	2020-03-24 INSERT TO INVALID CLICKS TABLE
--	CLICKS WITH BANNED REQUEST_IP
	IF EXISTS (SELECT 1 FROM V_fraud_banned_ips WHERE request_ip = @request_ip)
	BEGIN

		EXEC	[dbo].bi_click_insert_invalid_v4
				@source_post_id,
				@source_website_id,
				@dest_post_id,
				@dest_website_id ,
				@visitor_guid,
				@widget_id,
				@link_location,
				@country_code,
				@region_code,
				@geo_sub1_code,
				@geo_sub2_code,
				@recomendation_type_id,
				@cpc,
				@sub_id_string,
				@click_date,
				@visitor_ip,
				@request_ip,
				@referrer,
				1024,		--@status,
				@device_type,
				@device_os_family,
				@widget_profile,
				@os_id,
				@click_guid,
				1024		--@ab_test_variant;
				, @rec_date_time,
				@request_id
				;
		SET @click_id = SCOPE_IDENTITY();
		--SELECT 0 AS website_id,0 AS credits,0 AS paid_credits, @click_id as click_id;

		RETURN
	END;

	IF LEN(@visitor_ip)> 95
		SET @visitor_ip = LEFT(@visitor_ip,95)+'...';
	IF LEN(@request_ip)> 95
		SET @request_ip = LEFT(@request_ip,95)+'...';

	--user agent strings share the column width (512) with tbl_user_agents.user_agent;
	--truncate defensively the same way visitor_ip/request_ip are, leaving room for the suffix
	IF LEN(@request_ua) > 507
		SET @request_ua = LEFT(@request_ua,507)+'...';
	IF LEN(@click_ua) > 507
		SET @click_ua = LEFT(@click_ua,507)+'...';

	SELECT @is_paid=is_paid  FROM [dbo].[tbl_recommendation_types] WITH(NOLOCK) WHERE recomendation_type_id = @recomendation_type_id;

		IF @visitor_guid  = ''
			SET @v_visitor_guid = NULL
		ELSE IF @visitor_guid IS NOT NULL
			SET @v_visitor_guid = CONVERT(UNIQUEIDENTIFIER, @visitor_guid);

	IF @sub_id_string IS NULL
		SET @sub_id_string = '';

	IF @v_billingTypeID = 2 -- 'Pixel'
	BEGIN
		--SET @v_clickGuidHashCode =CHECKSUM(@click_guid);

		SELECT @v_pixel_type = pixel_type, @v_billingPixelExists = 1
		FROM dbo.tbl_pixels p WITH( NOLOCK, INDEX(IX_tbl_pixels_click_guid_hash_code_Filtered), FORCESEEK )
		WHERE
			p.click_guid_hash_code = @v_clickGuidHashCode AND
			p.click_guid = @click_guid AND
			p.is_billing_pixel = 1 AND
			p.click_guid_hash_code IS NOT NULL
		OPTION(RECOMPILE);

		IF @v_billingPixelExists = 0
			SET @v_isBilled = 0;
	END;

	--07/2017 cpm campaigns support - update variables for CPM campaign clicks
	IF @v_billingTypeID = 3 -- 'CPM campaigns'
		SET @v_isBilled = 0;

	IF @v_billingTypeID = 3 -- 'CPM campaigns'
		SET @is_paid = 0;

	IF @cpc > 0
		SET @v_CPC = @cpc;

	-- Extract SubID (via sub_id_string and website)
	BEGIN
		SELECT @v_sub_id = sub_id FROM dbo.tbl_websites_subid WITH(NOLOCK) WHERE website_id = @source_website_id AND sub_id_string = @sub_id_string;
		IF @v_sub_id IS NULL
		BEGIN
			-- Since we're working with many parallel threads, it is possible that more than one session try to insert same sub_id to the same website.
			-- So first one will succeed while all other sessions would fail on unique index violation. For that case we add TRY/CATCH block and in CATCH
			-- we try to extract it again.
			BEGIN TRY
				INSERT INTO dbo.tbl_websites_subid( website_id, sub_id_string )
				VALUES( @source_website_id, @sub_id_string );

				SET @v_sub_id = SCOPE_IDENTITY();
			END TRY
			BEGIN CATCH
				SELECT @v_sub_id = sub_id FROM dbo.tbl_websites_subid WITH(NOLOCK) WHERE website_id = @source_website_id AND sub_id_string = @sub_id_string;
			END CATCH;
		END;
	END;

	-- Extract UA id for request_ua (server/request-side User-Agent)
	IF @request_ua IS NOT NULL
	BEGIN
		SELECT @v_request_ua_id = ua_id FROM dbo.tbl_user_agents WITH(NOLOCK) WHERE user_agent = @request_ua;
		IF @v_request_ua_id IS NULL
		BEGIN
			-- Same race-condition handling as tbl_websites_subid above: concurrent
			-- sessions may try to insert the same new UA string; the loser of the
			-- unique index violation just re-reads the value the winner inserted.
			BEGIN TRY
				INSERT INTO dbo.tbl_user_agents( user_agent )
				VALUES( @request_ua );

				SET @v_request_ua_id = SCOPE_IDENTITY();
			END TRY
			BEGIN CATCH
				SELECT @v_request_ua_id = ua_id FROM dbo.tbl_user_agents WITH(NOLOCK) WHERE user_agent = @request_ua;
			END CATCH;
		END;
	END;

	-- Extract UA id for click_ua (browser/click-side User-Agent)
	-- The lookup predicate compares against the user_agent column, so it
	-- resolves in the column's collation automatically (correct dedup under
	-- any collation). We deliberately do NOT short-circuit on
	-- @click_ua = @request_ua: that variable comparison would use the DB
	-- default collation, which can disagree with the column's collation.
	IF @click_ua IS NOT NULL
	BEGIN
		SELECT @v_click_ua_id = ua_id FROM dbo.tbl_user_agents WITH(NOLOCK) WHERE user_agent = @click_ua;
		IF @v_click_ua_id IS NULL
		BEGIN
			BEGIN TRY
				INSERT INTO dbo.tbl_user_agents( user_agent )
				VALUES( @click_ua );

				SET @v_click_ua_id = SCOPE_IDENTITY();
			END TRY
			BEGIN CATCH
				SELECT @v_click_ua_id = ua_id FROM dbo.tbl_user_agents WITH(NOLOCK) WHERE user_agent = @click_ua;
			END CATCH;
		END;
	END;

	INSERT INTO dbo.tbl_bi_clicks (
		dest_post_id, source_post_id, country_code, widget_id, link_location, click_date_time, CPC, recomendation_type_id, sub_id, click_guid,
		visitor_ip, request_ip, referrer, widget_profile, click_guid_hash_code, billing_type_id, is_billed, is_boosted, source_website_id, visitor_guid, device_type, device_os_family,os_id, ab_test_variant, rec_date_time, region_code,geo_sub1_code,geo_sub2_code,request_id,request_ua_id,click_ua_id)
	VALUES(
		@dest_post_id, @source_post_id, @country_code, @widget_id, @link_location, @v_click_date_time, @v_CPC, @recomendation_type_id, @v_sub_id, @click_guid,
		@visitor_ip,@request_ip,@referrer, NULL, @v_clickGuidHashCode, @v_billingTypeID, @v_isBilled, 0, @source_website_id, @v_visitor_guid, @device_type, @device_os_family,@os_id, @ab_test_variant,
		@rec_date_time,@region_code,@geo_sub1_code,@geo_sub2_code, @request_id, @v_request_ua_id, @v_click_ua_id);

	SET @click_id = SCOPE_IDENTITY();

	--if it's an external click
	IF @source_website_id != @dest_website_id --AND @recomendation_type_id <> 4
	BEGIN
		SELECT @v_source_publisher_id = publisher_id FROM dbo.tbl_websites WITH(NOLOCK) WHERE website_id = @source_website_id;
		SELECT @v_dest_publisher_id = publisher_id FROM dbo.tbl_websites WITH(NOLOCK) WHERE website_id = @dest_website_id;

		--if it's from different publishers
		IF @v_source_publisher_id <> @v_dest_publisher_id
		BEGIN

			--check if it belongs to the same private network, that does not count credits
			--SET @v_source_network_id  = 0
			--SET @v_dest_network_id  = 0

			--SELECT @v_source_network_id = network_id FROM dbo.tbl_network_websites WITH(NOLOCK) WHERE website_id = @source_website_id;
			--SELECT @v_dest_network_id = network_id FROM dbo.tbl_network_websites WITH(NOLOCK) WHERE website_id = @dest_website_id;

			--if it's not from her campus (temp!!!) - the only private network that does not count credits
			IF
				--(@v_source_network_id <> 56 OR @v_dest_network_id <> 56) AND
				--(
					@is_paid = 0  OR  --@recomendation_type_id <> 4
					(
						@is_paid =1  AND -- @recomendation_type_id = 4
						NOT( @v_billingTypeID =2 /* Pixel */ AND @v_billingPixelExists = 0 )
					)
				--)
			BEGIN
				EXEC dbo.website_credits_update
					@click_id = @click_id,
					@source_website_id = @source_website_id,
					@dest_website_id = @dest_website_id,
					@country_code = @country_code,
					@CPC = @v_CPC,
					@click_date = @v_click_date_time,
					@recomendation_type_id = @recomendation_type_id;
			END

		END

		IF @is_paid = 1  AND NOT( @v_billingTypeID =2 /* Pixel */ AND @v_billingPixelExists = 0 ) --@recomendation_type_id = 4
			EXEC dbo.bi_ad_transaction_insert
				@click_id = @click_id,
				@click_date_time = @v_click_date_time,
				@website_id = @source_website_id,
				@campaign_id = @v_campaignID,
				@advertiser_id = @v_advertiserID,
				@user_id = @v_adBrokerUserID,
				@CPC = @v_CPC,
				@sub_id = @v_sub_id,
				@recomendation_type_id = @recomendation_type_id;

	END

	--SELECT 0 AS website_id,0 AS credits,0 AS paid_credits, @click_id as click_id;

	SET NOCOUNT OFF;
END



GO
