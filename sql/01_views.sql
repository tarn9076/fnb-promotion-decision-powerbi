-- =====================================================================
-- FnB_Portfolio — analytical views (SQLite; syntax portable to SQL Server)
-- Grain of FactSales: Date x Hotel x Outlet x MealPeriod x Channel x Promo
-- =====================================================================

-- 1) vw_channel_yield : what each channel earns AFTER discount, food cost and commission
DROP VIEW IF EXISTS vw_channel_yield;
CREATE VIEW vw_channel_yield AS
SELECT
    d.MonthYearSort,
    d.MonthYear,
    h.HotelName,
    o.OutletName,
    f.MealPeriod,
    c.ChannelName,
    CASE WHEN f.PromoID IS NULL THEN 'Full price' ELSE 'Promotion' END AS PriceType,
    SUM(f.Covers)                                  AS Covers,
    SUM(f.GrossRevenue)                            AS GrossRevenue,
    SUM(f.Discount)                                AS Discount,
    SUM(f.NetRevenue)                              AS NetRevenue,
    SUM(f.FoodCost)                                AS FoodCost,
    SUM(f.CommissionCost)                          AS CommissionCost,
    SUM(f.NetRevenue - f.FoodCost - f.CommissionCost) AS ContributionMargin,
    ROUND(1.0 * SUM(f.NetRevenue - f.FoodCost - f.CommissionCost) / NULLIF(SUM(f.Covers),0), 0) AS CM_per_Cover,
    ROUND(1.0 * SUM(f.NetRevenue) / NULLIF(SUM(f.Covers),0), 0)                                 AS NetAvgCheck
FROM FactSales f
JOIN DimDate    d ON d.Date     = f.Date
JOIN DimHotel   h ON h.HotelID  = f.HotelID
JOIN DimOutlet  o ON o.OutletID = f.OutletID
JOIN DimChannel c ON c.ChannelID = f.ChannelID
GROUP BY 1,2,3,4,5,6,7;

-- 2) vw_promo_baseline : one row per promo day.
--    Baseline = covers and full-price contribution on the SAME day last year (364 days back = same weekday),
--    same outlet x meal period, when no promo ran that day.
--    Why same-day-last-year and not "average of non-promo days": the average mixes high and low season and
--    over-states the baseline for promotions that run in low season (first version flagged every promo as Stop).
DROP VIEW IF EXISTS vw_promo_baseline;
CREATE VIEW vw_promo_baseline AS
WITH day AS (
    SELECT Date, OutletID, MealPeriod,
           SUM(Covers)                                                     AS DayCovers,
           SUM(NetRevenue - FoodCost - CommissionCost)                     AS DayContribution,
           SUM(CASE WHEN PromoID IS NULL THEN Covers END)                  AS FullPriceCovers,
           SUM(CASE WHEN PromoID IS NULL THEN NetRevenue - FoodCost - CommissionCost END) AS FullPriceContribution,
           MAX(CASE WHEN PromoID IS NOT NULL THEN 1 ELSE 0 END)            AS HasPromo
    FROM FactSales GROUP BY Date, OutletID, MealPeriod
)
SELECT p.PromoID, p.Date, p.OutletID, p.MealPeriod,
       p.PromoCovers, p.PromoContribution,
       d.DayCovers            AS CoversOnPromoDay,
       d.DayContribution      AS ContributionWithPromo,
       d.FullPriceCovers, d.FullPriceContribution,
       ly.Date                AS BaselineDate,
       ly.DayCovers           AS BaselineCovers
FROM (SELECT PromoID, Date, OutletID, MealPeriod, SUM(Covers) AS PromoCovers,
             SUM(NetRevenue - FoodCost - CommissionCost) AS PromoContribution
      FROM FactSales WHERE PromoID IS NOT NULL GROUP BY 1,2,3,4) p
JOIN day d  ON d.Date = p.Date AND d.OutletID = p.OutletID AND d.MealPeriod = p.MealPeriod
JOIN day ly ON ly.Date = date(p.Date, '-364 days') AND ly.OutletID = p.OutletID AND ly.MealPeriod = p.MealPeriod
           AND ly.HasPromo = 0;

-- 3) vw_promo_uplift : the decision table — one row per promotion.
--    LOCKED RULE (same in README, DAX and memo):
--      IncrementalCovers        = max(covers on promo days - baseline covers, 0)
--      CannibalisedCovers       = promo covers - incremental covers        (measured, not assumed)
--      CannibalisedShare (s)    = cannibalised / promo covers
--      CM_per_FullPriceCover    = full-price contribution / full-price covers on promo days
--      ContributionWithoutPromo = baseline covers x CM_per_FullPriceCover
--      IncrementalContribution  = contribution with promo - contribution without promo
--      BreakEvenCannibalisation (s*) = CM_per_PromoCover / CM_per_FullPriceCover
--        = "how large can the existing-guest share get before the promo stops paying"
--      Verdict (in DAX): Continue s <= 0.85 s* | Review 0.85 s* < s <= 1.15 s* | Stop s > 1.15 s*
--                        Stop + UpliftPct >= 20% -> "redesign candidate"
DROP VIEW IF EXISTS vw_promo_uplift;
CREATE VIEW vw_promo_uplift AS
WITH agg AS (
    SELECT PromoID,
           COUNT(*)                    AS PromoDays,
           SUM(BaselineCovers)         AS BaselineCovers,
           SUM(CoversOnPromoDay)       AS CoversOnPromoDays,
           SUM(PromoCovers)            AS PromoCovers,
           SUM(PromoContribution)      AS PromoContribution,
           SUM(ContributionWithPromo)  AS ContributionWithPromo,
           SUM(FullPriceCovers)        AS FullPriceCovers,
           SUM(FullPriceContribution)  AS FullPriceContribution
    FROM vw_promo_baseline GROUP BY PromoID
),
money AS (
    SELECT PromoID,
           SUM(GrossRevenue) AS GrossRevenue, SUM(Discount) AS Discount, SUM(NetRevenue) AS NetRevenue,
           SUM(FoodCost) AS FoodCost, SUM(CommissionCost) AS CommissionCost
    FROM FactSales WHERE PromoID IS NOT NULL GROUP BY PromoID
),
calc AS (
    SELECT a.*,
           MAX(a.CoversOnPromoDays - a.BaselineCovers, 0)                       AS IncrementalCovers,
           1.0 * a.FullPriceContribution / NULLIF(a.FullPriceCovers, 0)          AS CM_per_FullPriceCover,
           1.0 * a.PromoContribution     / NULLIF(a.PromoCovers, 0)              AS CM_per_PromoCover
    FROM agg a
)
SELECT dp.PromoID, dp.PromoName, o.OutletName, dp.MealPeriod, dp.TargetDayType, c.ChannelName, dp.DiscountPct,
       x.PromoDays, x.BaselineCovers, x.CoversOnPromoDays, x.PromoCovers,
       ROUND(1.0 * x.CoversOnPromoDays / NULLIF(x.BaselineCovers,0) - 1, 3)      AS UpliftPct,
       x.IncrementalCovers,
       x.PromoCovers - x.IncrementalCovers                                        AS CannibalisedCovers,
       ROUND(1.0 * (x.PromoCovers - x.IncrementalCovers) / NULLIF(x.PromoCovers,0), 3) AS CannibalisedShare,
       m.GrossRevenue, m.Discount, m.NetRevenue, m.FoodCost, m.CommissionCost,
       x.PromoContribution,
       ROUND(1.0 * x.PromoContribution / NULLIF(m.NetRevenue,0), 3)              AS PromoCM_Pct,
       ROUND(1.0 * m.Discount / NULLIF(x.PromoCovers,0), 0)                      AS DiscountPerCover,
       ROUND(x.CM_per_PromoCover, 0)                                             AS CM_per_PromoCover,
       ROUND(x.CM_per_FullPriceCover, 0)                                         AS CM_per_FullPriceCover,
       x.ContributionWithPromo,
       ROUND(x.BaselineCovers * x.CM_per_FullPriceCover, 0)                      AS ContributionWithoutPromo,
       ROUND(x.ContributionWithPromo - x.BaselineCovers * x.CM_per_FullPriceCover, 0) AS IncrementalContribution,
       ROUND(x.CM_per_PromoCover / NULLIF(x.CM_per_FullPriceCover,0), 3)         AS BreakEvenCannibalisation
FROM DimPromo dp
JOIN DimOutlet  o ON o.OutletID  = dp.OutletID
JOIN DimChannel c ON c.ChannelID = dp.ChannelID
JOIN calc  x ON x.PromoID = dp.PromoID
JOIN money m ON m.PromoID = dp.PromoID;
