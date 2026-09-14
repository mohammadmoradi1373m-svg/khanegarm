-- Applied to Supabase production project thovhvemaidbiekagome
create index if not exists idx_orders_created_at_desc on public.orders (created_at desc);
create index if not exists idx_reviews_created_at_desc on public.reviews (created_at desc);
create index if not exists idx_admin_todos_created_at_desc on public.admin_todos (created_at desc);
create index if not exists idx_guide_submissions_status_created_at_desc on public.guide_submissions (status, created_at desc);
