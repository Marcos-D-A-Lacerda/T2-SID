#!/bin/bash
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
