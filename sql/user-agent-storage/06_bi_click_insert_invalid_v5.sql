USE [BeaconSpark_data]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


-- ====================================================
-- v5 2026-07-02 - new input parameters @request_ua, @click_ua
--                  resolved to request_ua_id/click_ua_id via
--                  dbo.tbl_user_agents (get-or-create), mirroring
--                  bi_click_insert_internal_v5. Invalid/banned clicks
--                  now carry the same User-Agent references.
-- ====================================================
CREATE OR ALTER   PROCEDURE [dbo].[bi_click_insert_invalid_v5]
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
	@cpc DECIMAL(16,4) =0, --[ added by gabby - if cpc > 0 use it, otherwise get it from tbl_website_campaigns
	@sub_id_string NVARCHAR(256) =NULL,
	@click_date DATETIME =NULL,
	@visitor_ip VARCHAR(100) = NULL,
	@request_ip VARCHAR(100) = NULL,
	@referrer NVARCHAR(MAX) = NULL,
	@status int = 0,
	@device_type SMALLINT = -1,
	@device_os_family SMALLINT = -1,
	@widget_profile tinyint = NULL,
	@os_id SMALLINT = -1,
	@click_guid NVARCHAR(MAX)=NULL,
	@ab_test_variant int = 0,
	@rec_date_time DATETIME =NULL,
	@request_id VARCHAR(256) = '',
	@request_ua VARCHAR(512) = NULL,
	@click_ua VARCHAR(512) = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE
		@click_id BIGINT =0, @v_source_publisher_id INT, @v_dest_publisher_id INT, @v_source_network_id INT, @v_sub_id INT,
		@v_CPC DECIMAL(16,4) =0, @v_dest_network_id INT, @v_campaignID INT, @v_advertiserID INT, @v_adBrokerUserID INT,
		@v_click_date_time DATETIME =ISNULL(@click_date, GETDATE()), @v_visitor_guid UNIQUEIDENTIFIER,
		@v_request_ua_id INT = NULL, @v_click_ua_id INT = NULL,
		@v_clickGuidHashCode INT =CHECKSUM(@click_guid);

	--INSERT INTO [dbo].[tbl_bi_clicks_invalid_p_bulkinsertion_raw_input_data]
	--		(source_post_id,source_website_id,dest_post_id,dest_website_id,visitor_guid,widget_id,link_location,country_code,recomendation_type_id,cpc,--sub_id_string,
	--		 click_date,visitor_ip,request_ip,referrer,[status],device_type,device_os_family,widget_profile)
	--VALUES (@source_post_id,@source_website_id,@dest_post_id,@dest_website_id,@visitor_guid,@widget_id,@link_location,@country_code,@recomendation_type_id,@cpc, --@sub_id_string,
	--@click_date,@visitor_ip,@request_ip,@referrer,@status,@device_type,@device_os_family,@widget_profile);


	IF @visitor_guid IS NOT NULL
		SET @v_visitor_guid = CONVERT(UNIQUEIDENTIFIER, @visitor_guid);

	SELECT @v_CPC = CPC, @v_campaignID = campaign_id, @v_advertiserID = advertiser_id, @v_adBrokerUserID = ad_broker_user_id
	FROM dbo.tbl_website_campaigns AS twc WITH(NOLOCK)
	WHERE twc.website_id = @dest_website_id;

	IF @cpc > 0
		SET @v_CPC = @cpc;

	IF @sub_id_string IS NOT NULL AND @sub_id_string <> ''
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

	--user agent strings share the column width (512) with tbl_user_agents.user_agent;
	--truncate defensively the same way visitor_ip/request_ip are, leaving room for the suffix
	IF LEN(@request_ua) > 507
		SET @request_ua = LEFT(@request_ua,507)+'...';
	IF LEN(@click_ua) > 507
		SET @click_ua = LEFT(@click_ua,507)+'...';

	-- Extract UA id for request_ua (server/request-side User-Agent)
	-- NULLIF(...,'') treats an empty-string UA the same as no UA (id left NULL),
	-- so we never create a junk empty-string row in tbl_user_agents.
	IF NULLIF(@request_ua, '') IS NOT NULL
	BEGIN
		SELECT @v_request_ua_id = ua_id FROM dbo.tbl_user_agents WITH(NOLOCK) WHERE user_agent = @request_ua;
		IF @v_request_ua_id IS NULL
		BEGIN
			-- Same race-condition handling as tbl_websites_subid above: concurrent
			-- sessions may try to insert the same new UA string; the loser of the
			-- unique index violation just re-reads the value the winner inserted.
			BEGIN TRY
				INSERT INTO dbo.tbl_user_agents( user_agent, creation_date_time )
				VALUES( @request_ua, GETDATE() );

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
	IF NULLIF(@click_ua, '') IS NOT NULL
	BEGIN
		SELECT @v_click_ua_id = ua_id FROM dbo.tbl_user_agents WITH(NOLOCK) WHERE user_agent = @click_ua;
		IF @v_click_ua_id IS NULL
		BEGIN
			BEGIN TRY
				INSERT INTO dbo.tbl_user_agents( user_agent, creation_date_time )
				VALUES( @click_ua, GETDATE() );

				SET @v_click_ua_id = SCOPE_IDENTITY();
			END TRY
			BEGIN CATCH
				SELECT @v_click_ua_id = ua_id FROM dbo.tbl_user_agents WITH(NOLOCK) WHERE user_agent = @click_ua;
			END CATCH;
		END;
	END;

	INSERT INTO dbo.tbl_bi_clicks_invalid_p (dest_post_id, source_post_id, country_code, widget_id, link_location, click_date_time, CPC, recomendation_type_id, sub_id,visitor_ip,request_ip,referrer,click_status, widget_profile,visitor_guid, device_type, device_os_family,os_id,click_guid,click_guid_hash_code,ab_test_variant,rec_date_time,region_code,geo_sub1_code,geo_sub2_code, request_id,request_ua_id,click_ua_id)
	VALUES (@dest_post_id, @source_post_id, @country_code, @widget_id, @link_location, @v_click_date_time, @v_CPC, @recomendation_type_id, @v_sub_id,@visitor_ip,@request_ip,@referrer,@status,@widget_profile,@v_visitor_guid, @device_type, @device_os_family,@os_id,@click_guid,@v_clickGuidHashCode,@ab_test_variant,@rec_date_time,
	@region_code,@geo_sub1_code,@geo_sub2_code, @request_id, @v_request_ua_id, @v_click_ua_id);

	SET @click_id = SCOPE_IDENTITY();

	SET NOCOUNT OFF;
END

GO
