-- 20261120150000_heatmap_fixes.sql
-- Heatmap fixes: the dashboard's first tab was tracked as 'home' (now counted as 'new-check', the
-- tab the dashboard opens on); click points carry the device (m = phone) so phone and desktop
-- clicks are drawn on their own layout.
CREATE OR REPLACE FUNCTION public.admin_site_heat(p_days integer, p_page text, p_device text DEFAULT 'all', p_area text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  RETURN (
    WITH ev AS (
      -- 'home' = the dashboard's first tab before the tracker knew its name: that is "New check".
      SELECT e.id, e.created_at, e.user_id, e.sid, e.page, e.kind, e.x, e.y, e.doc_h, e.vw, e.label, e.dur,
             CASE WHEN e.page = 'dashboard' AND e.area = 'home' THEN 'new-check' ELSE e.area END AS area
      FROM public.site_events e
      WHERE created_at >= since AND page = p_page
        AND (p_device = 'all' OR (p_device = 'mobile' AND coalesce(vw, 1200) < 768) OR (p_device = 'desktop' AND coalesce(vw, 1200) >= 768))
    )
    SELECT jsonb_build_object(
      'totals', (SELECT jsonb_build_object(
          'clicks', count(*) FILTER (WHERE kind = 'click'),
          'views', count(*) FILTER (WHERE kind = 'view' AND coalesce(dur, 0) = 0),
          'visitors', count(DISTINCT coalesce(user_id::text, sid)),
          'customers', count(DISTINCT user_id)) FROM ev),
      'areas', coalesce((SELECT jsonb_agg(a ORDER BY (a->>'views')::int DESC) FROM (
          SELECT jsonb_build_object('area', area,
            'views', count(*) FILTER (WHERE kind = 'view' AND coalesce(dur, 0) = 0),
            'time', coalesce(sum(dur) FILTER (WHERE kind = 'view'), 0),
            'avg', coalesce(round(avg(dur) FILTER (WHERE kind = 'view' AND dur > 0)), 0),
            'clicks', count(*) FILTER (WHERE kind = 'click'),
            'visitors', count(DISTINCT coalesce(user_id::text, sid))) AS a
          FROM ev GROUP BY area) s), '[]'::jsonb),
      'labels', coalesce((SELECT jsonb_agg(l ORDER BY (l->>'n')::int DESC) FROM (
          SELECT jsonb_build_object('label', label, 'area', area, 'n', count(*)) AS l
          FROM ev WHERE kind = 'click' AND coalesce(label, '') <> ''
          GROUP BY label, area ORDER BY count(*) DESC LIMIT 40) s), '[]'::jsonb),
      'points', coalesce((SELECT jsonb_agg(jsonb_build_object('bx', bx, 'by', by_, 'n', n, 'm', m)) FROM (
          SELECT floor(x * 48)::int AS bx, floor(y / 24)::int AS by_, count(*) AS n, (coalesce(vw, 1200) < 768) AS m
          FROM ev WHERE kind = 'click' AND x IS NOT NULL AND y IS NOT NULL
            AND (p_area IS NULL OR area = p_area OR area LIKE p_area || ':%')
          GROUP BY 1, 2, 4) s), '[]'::jsonb),
      'scroll', coalesce((SELECT jsonb_agg(jsonb_build_object('b', b, 'n', n) ORDER BY b) FROM (
          SELECT least(floor(y * 10)::int, 9) AS b, count(*) AS n
          FROM ev WHERE kind = 'view' AND dur > 0 AND y IS NOT NULL
            AND (p_area IS NULL OR area = p_area OR area LIKE p_area || ':%')
          GROUP BY 1) s), '[]'::jsonb)
    ) FROM (SELECT 1) one
  );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_site_heat(integer, text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_site_heat(integer, text, text, text) TO authenticated;
