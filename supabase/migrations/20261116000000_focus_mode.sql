-- 20261116000000_focus_mode.sql
-- Focus mode data (bookmarks, notes, tasks, calendar events), private per account,
-- plus one shared board per account that others can join by invitation.
-- Rows with board_id NULL are private to their creator; rows with a board_id are visible to the board's members.

CREATE TABLE IF NOT EXISTS public.focus_boards (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id   uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  name       text NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.focus_board_members (
  board_id  uuid NOT NULL REFERENCES public.focus_boards(id) ON DELETE CASCADE,
  user_id   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role      text NOT NULL CHECK (role IN ('owner', 'collaborator')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (board_id, user_id)
);
CREATE TABLE IF NOT EXISTS public.focus_invitations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id      uuid NOT NULL REFERENCES public.focus_boards(id) ON DELETE CASCADE,
  inviter_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  invitee_email text NOT NULL CHECK (invitee_email = lower(invitee_email) AND length(invitee_email) BETWEEN 3 AND 254),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (board_id, invitee_email)
);

CREATE OR REPLACE FUNCTION public.focus_is_member(p_board uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$ SELECT EXISTS (SELECT 1 FROM public.focus_board_members WHERE board_id = p_board AND user_id = auth.uid()); $$;
REVOKE EXECUTE ON FUNCTION public.focus_is_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.focus_is_member(uuid) TO authenticated;

CREATE TABLE IF NOT EXISTS public.focus_bookmarks (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  board_id   uuid REFERENCES public.focus_boards(id) ON DELETE CASCADE,
  type       text NOT NULL CHECK (type IN ('bookmark', 'folder')),
  name       text NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
  url        text CHECK (url IS NULL OR (length(url) <= 2000 AND url ~* '^https?://')),
  folder_id  uuid REFERENCES public.focus_bookmarks(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.focus_notes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  board_id   uuid REFERENCES public.focus_boards(id) ON DELETE CASCADE,
  title      text NOT NULL DEFAULT 'Untitled Note' CHECK (length(title) <= 300),
  content    text NOT NULL DEFAULT '' CHECK (length(content) <= 200000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.focus_tasks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by  uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  board_id    uuid REFERENCES public.focus_boards(id) ON DELETE CASCADE,
  title       text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
  deadline    date,
  priority    text NOT NULL DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high')),
  done        boolean NOT NULL DEFAULT false,
  remind_at   timestamptz,
  description text CHECK (description IS NULL OR length(description) <= 5000),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.focus_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by  uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  board_id    uuid REFERENCES public.focus_boards(id) ON DELETE CASCADE,
  title       text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
  description text CHECK (description IS NULL OR length(description) <= 5000),
  start_at    timestamptz NOT NULL,
  end_at      timestamptz,
  all_day     boolean NOT NULL DEFAULT false,
  color       text NOT NULL DEFAULT '#06b6d4' CHECK (color ~* '^#[0-9a-f]{6}$'),
  remind_at   timestamptz,
  recurrence  text NOT NULL DEFAULT 'none' CHECK (recurrence IN ('none', 'weekly', 'monthly', 'yearly')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS focus_bookmarks_owner_idx ON public.focus_bookmarks (created_by, board_id);
CREATE INDEX IF NOT EXISTS focus_notes_owner_idx     ON public.focus_notes (created_by, board_id);
CREATE INDEX IF NOT EXISTS focus_tasks_owner_idx     ON public.focus_tasks (created_by, board_id);
CREATE INDEX IF NOT EXISTS focus_events_owner_idx    ON public.focus_events (created_by, board_id, start_at);

ALTER TABLE public.focus_boards        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.focus_board_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.focus_invitations   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.focus_bookmarks     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.focus_notes         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.focus_tasks         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.focus_events        ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.focus_boards, public.focus_board_members, public.focus_invitations,
              public.focus_bookmarks, public.focus_notes, public.focus_tasks, public.focus_events FROM anon, authenticated;
GRANT SELECT ON public.focus_boards, public.focus_board_members, public.focus_invitations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.focus_bookmarks, public.focus_notes, public.focus_tasks, public.focus_events TO authenticated;

CREATE POLICY focus_boards_read ON public.focus_boards FOR SELECT TO authenticated USING (public.focus_is_member(id));
CREATE POLICY focus_members_read ON public.focus_board_members FOR SELECT TO authenticated USING (public.focus_is_member(board_id));
CREATE POLICY focus_invites_read ON public.focus_invitations FOR SELECT TO authenticated USING (inviter_id = auth.uid());

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['focus_bookmarks', 'focus_notes', 'focus_tasks', 'focus_events'] LOOP
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING ((board_id IS NULL AND created_by = auth.uid()) OR (board_id IS NOT NULL AND public.focus_is_member(board_id)))', t || '_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (created_by = auth.uid() AND (board_id IS NULL OR public.focus_is_member(board_id)))', t || '_insert', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (created_by = auth.uid())', t || '_delete', t);
  END LOOP;
END $$;
-- Bookmarks and events: only their creator edits them. Notes and tasks: board members may edit them too
-- (a shared note is written together; any member can tick a shared task).
CREATE POLICY focus_bookmarks_update ON public.focus_bookmarks FOR UPDATE TO authenticated
  USING (created_by = auth.uid()) WITH CHECK (created_by = auth.uid() AND (board_id IS NULL OR public.focus_is_member(board_id)));
CREATE POLICY focus_events_update ON public.focus_events FOR UPDATE TO authenticated
  USING (created_by = auth.uid()) WITH CHECK (created_by = auth.uid() AND (board_id IS NULL OR public.focus_is_member(board_id)));
CREATE POLICY focus_notes_update ON public.focus_notes FOR UPDATE TO authenticated
  USING ((board_id IS NULL AND created_by = auth.uid()) OR (board_id IS NOT NULL AND public.focus_is_member(board_id)))
  WITH CHECK ((board_id IS NULL AND created_by = auth.uid()) OR (board_id IS NOT NULL AND public.focus_is_member(board_id)));
CREATE POLICY focus_tasks_update ON public.focus_tasks FOR UPDATE TO authenticated
  USING ((board_id IS NULL AND created_by = auth.uid()) OR (board_id IS NOT NULL AND public.focus_is_member(board_id)))
  WITH CHECK ((board_id IS NULL AND created_by = auth.uid()) OR (board_id IS NOT NULL AND public.focus_is_member(board_id)));

-- Boards I belong to (my own and the ones I joined).
CREATE OR REPLACE FUNCTION public.focus_my_boards()
RETURNS TABLE(id uuid, name text, role text, owner_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT b.id, b.name, m.role, b.owner_id
  FROM public.focus_board_members m JOIN public.focus_boards b ON b.id = m.board_id
  WHERE m.user_id = auth.uid()
  ORDER BY (m.role = 'owner') DESC, m.joined_at;
$$;
REVOKE EXECUTE ON FUNCTION public.focus_my_boards() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.focus_my_boards() TO authenticated;

-- Invite by email. Creates my shared board the first time. The invitee sees it in their own Focus mode.
CREATE OR REPLACE FUNCTION public.focus_invite(p_email text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  uid uuid := auth.uid();
  me record;
  em text := lower(trim(p_email));
  bid uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  IF em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'invalid_email'; END IF;
  SELECT email, raw_user_meta_data INTO me FROM auth.users WHERE id = uid;
  IF lower(me.email) = em THEN RAISE EXCEPTION 'self_invite'; END IF;
  INSERT INTO public.focus_boards (owner_id, name)
  VALUES (uid, left(coalesce(nullif(me.raw_user_meta_data->>'full_name', ''), split_part(me.email, '@', 1)), 60) || ' — Focus')
  ON CONFLICT (owner_id) DO NOTHING;
  SELECT id INTO bid FROM public.focus_boards WHERE owner_id = uid;
  INSERT INTO public.focus_board_members (board_id, user_id, role) VALUES (bid, uid, 'owner') ON CONFLICT DO NOTHING;
  IF (SELECT count(*) FROM public.focus_invitations WHERE board_id = bid AND status = 'pending') >= 20 THEN
    RAISE EXCEPTION 'too_many_pending';
  END IF;
  INSERT INTO public.focus_invitations (board_id, inviter_id, invitee_email)
  VALUES (bid, uid, em)
  ON CONFLICT (board_id, invitee_email) DO UPDATE SET status = 'pending', created_at = now()
  WHERE public.focus_invitations.status = 'declined';
  RETURN 'sent';
END;
$$;
REVOKE EXECUTE ON FUNCTION public.focus_invite(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.focus_invite(text) TO authenticated;

-- Invitations waiting for me (matched on my account email).
CREATE OR REPLACE FUNCTION public.focus_pending_invites()
RETURNS TABLE(id uuid, board_name text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT i.id, b.name, i.created_at
  FROM public.focus_invitations i JOIN public.focus_boards b ON b.id = i.board_id
  WHERE i.status = 'pending'
    AND i.invitee_email = (SELECT lower(email) FROM auth.users WHERE id = auth.uid())
    AND b.owner_id <> auth.uid()
  ORDER BY i.created_at DESC;
$$;
REVOKE EXECUTE ON FUNCTION public.focus_pending_invites() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.focus_pending_invites() TO authenticated;

CREATE OR REPLACE FUNCTION public.focus_respond_invite(p_id uuid, p_accept boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE inv record; myemail text;
BEGIN
  SELECT lower(email) INTO myemail FROM auth.users WHERE id = auth.uid();
  SELECT * INTO inv FROM public.focus_invitations WHERE id = p_id AND status = 'pending' AND invitee_email = myemail;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation not found'; END IF;
  UPDATE public.focus_invitations SET status = CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END WHERE id = p_id;
  IF p_accept THEN
    INSERT INTO public.focus_board_members (board_id, user_id, role) VALUES (inv.board_id, auth.uid(), 'collaborator') ON CONFLICT DO NOTHING;
  END IF;
  RETURN CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.focus_respond_invite(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.focus_respond_invite(uuid, boolean) TO authenticated;
