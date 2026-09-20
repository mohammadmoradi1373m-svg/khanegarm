-- OWLI / خانه‌گرم
-- Applied to Supabase project thovhvemaidbiekagome on 2026-09-20.
-- Prevent anonymous/public execution of admin SECURITY DEFINER RPCs.
revoke execute on function public.admin_bulk_set_order_status(uuid[], integer) from public;
revoke execute on function public.admin_cancel_order(uuid) from public;
revoke execute on function public.admin_confirm_order_payment(uuid) from public;
revoke execute on function public.admin_delete_pack(uuid) from public;
revoke execute on function public.admin_delete_product_discount(uuid) from public;
revoke execute on function public.admin_save_pack(uuid, text, text, text, text, integer, text, boolean, timestamptz, timestamptz, jsonb) from public;
revoke execute on function public.admin_save_product_discount(uuid, text, text, text, integer, boolean, timestamptz, timestamptz) from public;
revoke execute on function public.admin_set_order_status(uuid, integer) from public;
revoke execute on function public.admin_update_order_details(uuid, text, text, text, text, text) from public;
