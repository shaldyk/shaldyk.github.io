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
-- Index design (Design A) - chosen for a continuously
-- churning value set (bots/spoofed UAs keep introducing
-- new strings, so inserts never fully stop):
--   - CLUSTERED PK on ua_id (INT IDENTITY): inserts are
--     append-only/monotonic -> no data-row page splits,
--     minimal fragmentation on the hot insert path.
--   - UNIQUE NONCLUSTERED index on user_agent: enforces
--     dedup and serves the "does this UA already exist"
--     lookup; it is covering for user_agent -> ua_id
--     (carries ua_id as its locator). Being nonclustered,
--     it fragments on random string inserts but is small
--     and cheap to REORGANIZE/REBUILD without moving table
--     data.
--     Collation Latin1_General_CI_AS matches the database
--     default (and tbl_websites_subid.sub_id_string), keeping
--     the column consistent with the rest of the schema and
--     avoiding "cannot resolve collation conflict" errors when
--     user_agent is joined/compared in ad-hoc analytics.
--     Dedup is therefore case-insensitive (rarely material for
--     real UA strings).
--   - ua_id -> user_agent bulk resolution (analytics joins
--     from tbl_bi_clicks) is a clustered seek/scan of this
--     small, buffer-pool-resident table; cost is dominated
--     by the table size, not the index layout.
--   - PAGE compression: UA strings share large boilerplate
--     prefixes, so page compression shrinks the table and
--     keeps more of it cached. Easily removed if undesired.
--   - No FOREIGN KEY from tbl_bi_clicks (matches how sub_id
--     is not FK-constrained to tbl_websites_subid); a hot
--     insert path avoids the per-row FK check and relies on
--     the proc's get-or-create logic for integrity.
-- ====================================================
CREATE TABLE [dbo].[tbl_user_agents](
	[ua_id] [int] IDENTITY(1,1) NOT NULL,
	[user_agent] [varchar](512) COLLATE Latin1_General_CI_AS NOT NULL,
	[creation_date_time] [datetime] NULL,
 CONSTRAINT [PK_tbl_user_agents] PRIMARY KEY CLUSTERED
(
	[ua_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = ON, DATA_COMPRESSION = PAGE) ON [PRIMARY]
) ON [PRIMARY]
GO

SET ANSI_PADDING ON
GO

CREATE UNIQUE NONCLUSTERED INDEX [IX_tbl_user_agents_user_agent] ON [dbo].[tbl_user_agents]
(
	[user_agent] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF, DATA_COMPRESSION = PAGE) ON [PRIMARY]
GO
