-- 20261120110000_site_heatmap.sql
-- Click and page-view tracking for the admin Heatmap tab.
-- Visitors and customers only write through log_site_events() (validated, capped per call);
-- only admins can read. No typed text or chat content is ever stored: just where a click
-- landed, the label of the button/link, the page area (tab or section) and time spent.

CREATE TABLE IF NOT EXISTS public.site_events (
  id         bigserial PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  user_id    uuid,                       -- signed-in customer, if any
  sid        text,                       -- random id of one browser tab session
  page       text NOT NULL,              -- 'index' | 'dashboard'
  area       text,                       -- dashboard tab (e.g. 'wallet', 'academic:store') or 'index'
  kind       text NOT NULL CHECK (kind IN ('click', 'view')),
  x          real,                       -- click: 0..1 across the page width
  y          real,                       -- click: px from the top of the page; view: deepest scroll 0..1
  doc_h      integer,
  vw         integer,                    -- viewport width (mobile < 768)
  label      text,
  dur        integer                     -- view: seconds spent
);
CREATE INDEX IF NOT EXISTS site_events_created_idx ON public.site_events (created_at DESC);
CREATE INDEX IF NOT EXISTS site_events_page_idx ON public.site_events (page, kind, created_at DESC);
ALTER TABLE public.site_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read site_events" ON public.site_events;
CREATE POLICY "Admins read site_events" ON public.site_events FOR SELECT USING (public.is_admin());

-- Batch insert from the site (at most 60 events per call, values clamped).
CREATE OR REPLACE FUNCTION public.log_site_events(p_events jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE e jsonb; n int := 0;
BEGIN
  IF jsonb_typeof(p_events) <> 'array' THEN RETURN 0; END IF;
  FOR e IN SELECT * FROM jsonb_array_elements(p_events) LIMIT 60 LOOP
    CONTINUE WHEN coalesce(e->>'kind', '') NOT IN ('click', 'view');
    CONTINUE WHEN coalesce(e->>'page', '') NOT IN ('index', 'dashboard');
    INSERT INTO public.site_events (user_id, sid, page, area, kind, x, y, doc_h, vw, label, dur)
    VALUES (auth.uid(),
            left(e->>'sid', 40),
            e->>'page',
            left(e->>'area', 80),
            e->>'kind',
            CASE WHEN (e->>'x') ~ '^[0-9.]+$' THEN least(greatest((e->>'x')::real, 0), 1) END,
            CASE WHEN (e->>'y') ~ '^[0-9.]+$' THEN least((e->>'y')::real, 100000) END,
            CASE WHEN (e->>'doc_h') ~ '^[0-9]+$' THEN least((e->>'doc_h')::int, 200000) END,
            CASE WHEN (e->>'vw') ~ '^[0-9]+$' THEN least((e->>'vw')::int, 10000) END,
            left(e->>'label', 80),
            CASE WHEN (e->>'dur') ~ '^[0-9]+$' THEN least((e->>'dur')::int, 3600) END);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION public.log_site_events(jsonb) FROM public;
GRANT EXECUTE ON FUNCTION public.log_site_events(jsonb) TO anon, authenticated;

-- Everything the Heatmap tab shows, computed on the server.
-- p_device: 'all' | 'desktop' | 'mobile'
CREATE OR REPLACE FUNCTION public.admin_site_heat(p_days integer, p_page text, p_device text DEFAULT 'all')
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'not allowed'; END IF;
  RETURN (
    WITH ev AS (
      SELECT * FROM public.site_events
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
      'points', coalesce((SELECT jsonb_agg(jsonb_build_object('bx', bx, 'by', by_, 'n', n)) FROM (
          SELECT floor(x * 48)::int AS bx, floor(y / 24)::int AS by_, count(*) AS n
          FROM ev WHERE kind = 'click' AND x IS NOT NULL AND y IS NOT NULL
          GROUP BY 1, 2) s), '[]'::jsonb),
      'scroll', coalesce((SELECT jsonb_agg(jsonb_build_object('b', b, 'n', n) ORDER BY b) FROM (
          SELECT least(floor(y * 10)::int, 9) AS b, count(*) AS n
          FROM ev WHERE kind = 'view' AND dur > 0 AND y IS NOT NULL
          GROUP BY 1) s), '[]'::jsonb)
    ) FROM (SELECT 1) one
  );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_site_heat(integer, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_site_heat(integer, text, text) TO authenticated;
