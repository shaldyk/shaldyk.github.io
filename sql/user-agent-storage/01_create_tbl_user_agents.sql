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
-- Conventions mirror dbo.tbl_websites_subid:
--   - IDENTITY surrogate key (ua_id) as a NONCLUSTERED PK.
--   - The value column (user_agent) carries the UNIQUE
--     CLUSTERED index, so the "does this UA already exist"
--     lookup on the insert hot path is a clustered seek.
--   - creation_date_time audit column, nullable.
--   - No FOREIGN KEY from tbl_bi_clicks (matches how sub_id
--     is not FK-constrained to tbl_websites_subid); a hot
--     insert path avoids the per-row FK check and relies on
--     the proc's get-or-create logic for integrity.
-- ====================================================
CREATE TABLE [dbo].[tbl_user_agents](
	[ua_id] [int] IDENTITY(1,1) NOT NULL,
	[user_agent] [varchar](512) COLLATE Latin1_General_CI_AS NOT NULL,
	[creation_date_time] [datetime] NULL,
 CONSTRAINT [PK_tbl_user_agents] PRIMARY KEY NONCLUSTERED
(
	[ua_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

SET ANSI_PADDING ON
GO

CREATE UNIQUE CLUSTERED INDEX [IX_tbl_user_agents_user_agent] ON [dbo].[tbl_user_agents]
(
	[user_agent] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
