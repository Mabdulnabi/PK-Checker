-- 20261116010000_focus_board_people.sql
-- Members of a shared Focus board (name, avatar, role) for the avatar row in Shared mode.
-- Only members of that board get an answer; emails are not returned.
CREATE OR REPLACE FUNCTION public.focus_board_people(p_board uuid)
RETURNS TABLE(user_id uuid, name text, avatar_url text, role text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT m.user_id,
         coalesce(nullif(trim(p.full_name), ''), 'Member') AS name,
         CASE WHEN p.avatar_url ~* '^https?://' THEN p.avatar_url END AS avatar_url,
         m.role
  FROM public.focus_board_members m
  LEFT JOIN public.users_profile p ON p.user_id = m.user_id
  WHERE m.board_id = p_board
    AND public.focus_is_member(p_board)
  ORDER BY (m.role = 'owner') DESC, m.joined_at;
$$;
REVOKE EXECUTE ON FUNCTION public.focus_board_people(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.focus_board_people(uuid) TO authenticated;
