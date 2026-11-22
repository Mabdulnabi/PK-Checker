-- Any order that ends in failure gives its slot back, whatever path failed it
-- (API refusal, stuck order failed later, admin rejection, cancellation).
-- Before, the trigger only refunded the old wallet_transactions credit, and slots (slot_usages)
-- were returned only by some edge-function paths: an order failed later from 'run' kept its slot.
-- release_slot() only changes a 'reserved' usage, so it can never return a slot twice.
CREATE OR REPLACE FUNCTION public.trg_refund_on_order_failure()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_debit_amount numeric;
  v_balance_before numeric;
  v_balance_after numeric;
  v_already_refunded boolean;
BEGIN
  -- Only act on a genuine transition INTO a failure state.
  IF NEW.status NOT IN ('rejected','error','failed_invalid','cancelled')
     OR OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- The slot taken for this order goes back to the customer.
  UPDATE slot_usages SET status = 'released', updated_at = now()
   WHERE order_id = NEW.id AND status = 'reserved';

  -- Old wallet credits (accounts from before slots), as before.
  SELECT EXISTS(
    SELECT 1 FROM wallet_transactions WHERE order_id = NEW.id AND type = 'credit'
  ) INTO v_already_refunded;
  IF v_already_refunded THEN
    RETURN NEW;
  END IF;

  SELECT amount INTO v_debit_amount
  FROM wallet_transactions WHERE order_id = NEW.id AND type = 'debit'
  ORDER BY created_at DESC LIMIT 1;
  IF v_debit_amount IS NULL THEN
    RETURN NEW; -- nothing was ever deducted for this order
  END IF;

  SELECT balance_after INTO v_balance_before
  FROM wallet_transactions WHERE user_id = NEW.user_id ORDER BY created_at DESC LIMIT 1;
  v_balance_before := COALESCE(v_balance_before, 0);
  v_balance_after := v_balance_before + v_debit_amount;

  INSERT INTO wallet_transactions (user_id, type, amount, balance_before, balance_after, order_id, description)
  VALUES (NEW.user_id, 'credit', v_debit_amount, v_balance_before, v_balance_after, NEW.id,
          'استرداد كريديت — تلقائي عند تغيير حالة الطلب لـ ' || NEW.status);

  RETURN NEW;
END;
$function$;

-- Slots still held by orders that already failed (PK13-261122-3 at the time of writing) go back now.
UPDATE public.slot_usages su SET status = 'released', updated_at = now()
  FROM public.orders o
 WHERE su.order_id = o.id AND su.status = 'reserved'
   AND o.status IN ('rejected','error','failed_invalid','cancelled');
