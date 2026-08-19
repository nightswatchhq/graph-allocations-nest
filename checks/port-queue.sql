-- Pinned fixture: the shape of the queue, which is the thing that regresses if the join breaks.
SELECT COUNT(*) AS unserved_signalled,
       COUNT(*) FILTER (WHERE net_signal > 1000) AS unserved_over_1000,
       MAX(net_signal) AS largest_net_signal
FROM port_queue;
