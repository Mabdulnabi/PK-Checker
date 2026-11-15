-- 20261115070000_admin_delete_any_chat_message.sql
-- Admins could only delete messages they sent themselves, so "delete whole chat" (and deleting a
-- customer message) silently removed nothing. Admins may now delete any chat message.

DROP POLICY IF EXISTS "Admins can delete their messages" ON public.chat_messages;
DROP POLICY IF EXISTS "Admins can delete chat messages" ON public.chat_messages;
CREATE POLICY "Admins can delete chat messages" ON public.chat_messages
  FOR DELETE TO public
  USING (public.is_admin());
