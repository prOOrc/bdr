SELECT * FROM bdr_regress_variables()
\gset

\set VERBOSITY terse

\c :node1_dsn
CREATE EXTENSION bdr CASCADE;

\c :node2_dsn
CREATE EXTENSION bdr CASCADE;

\c :node1_dsn

-- We should be doing a bdr node create/join here but we don't yet have the
-- interfaces for that. We're just dummied up so far. So create a pglogical
-- node, and let that bring up BDR because the BDR plugin is loaded, even
-- though no actual BDR node is created yet.

SELECT *
FROM pglogical.create_node(node_name := 'node1', dsn := :'node1_dsn' || ' user=super');

-- Create the BDR node
--
-- Doing it in this order is racey since pglogical will start the manager before
-- we can reliably create the bdr node entries. We'll have to restart pglogical
-- with pg_terminate_backend afterwards.

INSERT INTO bdr.node_group(node_group_id, node_group_name)
VALUES (4, 'dummy_nodegroup');

INSERT INTO bdr.node(pglogical_node_id, node_group_id)
SELECT node_id, 4 FROM pglogical.local_node;


\c :node2_dsn

-- Manually create a second node
SELECT *
FROM pglogical.create_node(node_name := 'node2', dsn := :'node2_dsn' || ' user=super');

INSERT INTO bdr.node_group(node_group_id, node_group_name)
VALUES (4, 'dummy_nodegroup');

INSERT INTO bdr.node(pglogical_node_id, node_group_id)
SELECT node_id, 4 FROM pglogical.local_node;

-- Subscribe to the first node
SELECT * FROM pglogical.create_subscription(
    subscription_name := 'to_node1',
    provider_dsn := ( :'node1_dsn' || ' user=super' ),
    synchronize_structure := true,
    forward_origins := '{}');

-- and set the subscription as 'isinternal' so BDR thinks BDR owns it.
UPDATE pglogical.subscription SET sub_isinternal = true;

-- Wait for the initial copy to finish
--
-- If we don't do this, we'll usually kill the apply worker during init
-- and it won't retry since it doesn't know if the restore was partial
-- last time around

DO LANGUAGE plpgsql $$
BEGIN
  WHILE (SELECT status <> 'replicating' FROM pglogical.show_subscription_status())
  LOOP
    PERFORM pg_sleep(0.5);
  END LOOP;
END;
$$;


SELECT * FROM pglogical.show_subscription_status();

SELECT pg_sleep(5);

SELECT * FROM pglogical.show_subscription_status();

\c :node1_dsn

-- Subscribe to the second node and make the subscription 'internal'
-- but this time don't sync structure.
SELECT * FROM pglogical.create_subscription(
    subscription_name := 'to_node2',
    provider_dsn := ( :'node2_dsn' || ' user=super' ),
    synchronize_structure := false,
    forward_origins := '{}');

UPDATE pglogical.subscription SET sub_isinternal = true;

DO LANGUAGE plpgsql $$
BEGIN
  WHILE (SELECT status <> 'replicating' FROM pglogical.show_subscription_status())
  LOOP
    PERFORM pg_sleep(0.5);
  END LOOP;
END;
$$;

-- Now, since BDR doesn't know we changed any catalogs etc,
-- restart pglogical to make the plugin re-read its config


SET client_min_messages = error;

CREATE TEMPORARY TABLE throwaway AS
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid();

DROP TABLE throwaway;

SET client_min_messages = notice;

-- Wait for it to start up
SELECT pg_sleep(10);

-- ... and watch what happens. They should chat to each other
-- over their message brokers, delivering consensus messages
-- to each other.
SELECT pg_sleep(30);


SELECT * FROM pg_stat_replication;
SELECT * FROM pg_replication_slots;
SELECT * FROM pg_stat_activity;
