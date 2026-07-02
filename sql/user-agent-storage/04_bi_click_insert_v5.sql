USE [BeaconSpark_data]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


-- ====================================================
-- Author:		Sergey
-- Create date: July 2021
-- v5 2026-07-02 - new input parameters @request_ua, @click_ua
--                  passed through to bi_click_insert_internal_v5
--                  (User-Agent capture via dbo.tbl_user_agents)
-- Description:
-- ====================================================
CREATE OR ALTER   PROCEDURE [dbo].[bi_click_insert_v5]
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
	@click_ua VARCHAR(512) = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE
		@click_id BIGINT =0, @v_campaignID INT;
/*
	INSERT INTO [bi_click_insert_v2_input_params] (
		source_post_id,
		source_website_id,
		dest_post_id,
		dest_website_id,
		visitor_guid,
		widget_id,
		link_location,
		country_code,
		region_code,
		geo_sub1_code,
		geo_sub2_code,
		recomendation_type_id,
		cpc,
		sub_id_string,
		click_date,
		click_guid,
		visitor_ip,
		request_ip,
		referrer,
		device_type,
		device_os_family,
		widget_profile,
		os_id,
		ab_test_variant,
		rec_date_time
	)
	VALUES (
		@source_post_id,
		@source_website_id,
		@dest_post_id,
		@dest_website_id,
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
		@click_guid,
		@visitor_ip,
		@request_ip,
		@referrer,
		@device_type,
		@device_os_family,
		@widget_profile,
		@os_id ,
		@ab_test_variant,
		@rec_date_time
	)
*/

	SELECT @v_campaignID = campaign_id
	FROM dbo.tbl_website_campaigns AS twc WITH(NOLOCK)
	WHERE twc.website_id = @dest_website_id;

	BEGIN
		EXEC [bi_click_insert_internal_v5]
			@source_post_id =@source_post_id,
			@source_website_id =@source_website_id,
			@dest_post_id=@dest_post_id,
			@dest_website_id=@dest_website_id,
			@visitor_guid=@visitor_guid,
			@widget_id=@widget_id,
			@link_location=@link_location,
			@country_code=@country_code,
			@region_code =@region_code,
			@geo_sub1_code = @geo_sub1_code,
			@geo_sub2_code=@geo_sub2_code,
			@recomendation_type_id=@recomendation_type_id,
			@cpc=@cpc,
			@sub_id_string=@sub_id_string,
			@click_date=@click_date,
			@click_guid=@click_guid,
			@visitor_ip=@visitor_ip,
			@request_ip=@request_ip,
			@referrer=@referrer,
			@device_type=@device_type,
			@device_os_family=@device_os_family,
			@widget_profile =@widget_profile,
			@os_id =@os_id,
			@ab_test_variant =@ab_test_variant,
			@rec_date_time=@rec_date_time,
			@request_id = @request_id,
			@request_ua = @request_ua,
			@click_ua = @click_ua,
			@click_id =@click_id output


		SELECT 0 AS website_id,0 AS credits,0 AS paid_credits, @click_id as click_id;
	END


	SET NOCOUNT OFF;
END
GO
