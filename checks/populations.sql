-- Pinned fixture: the denominators. If these move without a backfill, something is wrong upstream.
SELECT (SELECT COUNT(*) FROM deployment_signal) AS deployments_ever_signalled,
       (SELECT COUNT(*) FROM deployment_signal WHERE net_signal > 0) AS still_signalled,
       (SELECT COUNT(*) FROM open_allocations) AS deployments_with_open_alloc;
